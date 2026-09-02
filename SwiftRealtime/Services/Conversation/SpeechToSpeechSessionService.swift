import Foundation
import os

/// Runs a two-way speech conversation: microphone capture, the
/// realtime socket, assistant playback, and every way the session
/// can end.
///
/// The service reports itself only through `snapshots` and never
/// touches view state. Turn-taking lives in `ConversationTurnTaking`
/// and the socket, lease and task plumbing in
/// `RealtimeSessionRuntime`; what is left here is the lifecycle —
/// start, stop, relaunch, suspend, fail — and the wiring between
/// them.
final class SpeechToSpeechSessionService:
    ConversationSessionController, @unchecked Sendable
{
    let audioSession: any RealtimeAudioSession
    let sessionFactory: RealtimeSessionFactory
    let recorder: any PcmAudioRecorder
    let player: any PcmAudioPlayer
    let model: ModelDefinition
    /// Zero — no ceiling. The server already ends a quiet task; the
    /// client cap exists for tests.
    let maxSessionDuration: Duration
    /// How long a reconnect to the task the app already holds may
    /// take before a fresh task is launched instead.
    let reconnectTimeout: Duration
    private(set) var parameters: ModelParameterValues

    private static let transcriptParser = ConversationTranscriptParser()
    private static let failureMapper = RealtimeFailureMapper(
        fallbackMessage:
        "The conversation session could not be completed.",
    )

    let snapshots: AsyncStream<ConversationSessionSnapshot>
    private let snapshotSink: AsyncStream<
        ConversationSessionSnapshot,
    >.Continuation
    private let snapshotState = OSAllocatedUnfairLock(
        initialState: ConversationSessionSnapshot(),
    )

    private let clock: any RealtimeClock
    private let runtime: RealtimeSessionRuntime
    private let turnTaking: ConversationTurnTaking
    private let micWatchdog: ConversationMicWatchdog
    private let recovery: ConversationRecoveryPolicy
    private let suspension: ConversationSuspension
    private let routeWatcher: RealtimeAudioRouteWatcher

    private let startFlight = SingleFlight()
    private let stopFlight = SingleFlight()
    private let relaunchFlight = SingleFlight()
    private var pcmTask: Task<Void, Never>?
    private var naturalCompletion: Task<Void, Never>?
    private var naturalCompletionRunning = false
    private var watchdogOperationId = 0

    init(
        audioSession: any RealtimeAudioSession,
        apiClient: any WiroApiClient,
        sessionFactory: @escaping RealtimeSessionFactory,
        recorder: any PcmAudioRecorder,
        player: any PcmAudioPlayer,
        sessionGuard: RealtimeSessionGuard,
        model: ModelDefinition,
        parameters: ModelParameterValues,
        suspendGracePeriod: Duration,
        maxSessionDuration: Duration = .zero,
        reconnectTimeout: Duration = .seconds(4),
        terminalTimeout: Duration = .seconds(3),
        maxRetryAttempts: Int = 5,
        retryBaseDelay: Duration = .milliseconds(500),
        micStallTimeout: Duration = .seconds(3),
        autoRestartDelay: Duration = .seconds(5),
        maxAutoRestarts: Int = 2,
        interruptHoldTimeout: Duration = .milliseconds(900),
        interruptHoldCooldown: Duration = .milliseconds(1_500),
        noiseGate: PcmNoiseGate? = nil,
        clock: any RealtimeClock = ContinuousClock(),
    ) {
        self.clock = clock
        self.audioSession = audioSession
        self.sessionFactory = sessionFactory
        self.recorder = recorder
        self.player = player
        self.model = model
        self.parameters = parameters
        self.maxSessionDuration = maxSessionDuration
        self.reconnectTimeout = reconnectTimeout
        let stream = AsyncStream<ConversationSessionSnapshot>
            .makeStream()
        snapshots = stream.stream
        snapshotSink = stream.continuation
        let owner = WeakOwner<SpeechToSpeechSessionService>()
        runtime = RealtimeSessionRuntime(
            owner: .conversation,
            apiClient: apiClient,
            sessionGuard: sessionGuard,
            terminalTimeout: terminalTimeout,
        )
        turnTaking = ConversationTurnTaking(
            player: player,
            noiseGate: noiseGate,
            holdTimeout: interruptHoldTimeout,
            holdCooldown: interruptHoldCooldown,
            clock: clock,
            onEvent: { [owner] event in
                owner.owner?.runtime.record(event)
            },
        )
        micWatchdog = ConversationMicWatchdog(
            onStall: { [owner] in
                owner.owner?.handleMicStall()
            },
            stallTimeout: micStallTimeout,
            clock: clock,
        )
        recovery = ConversationRecoveryPolicy(
            maxRetryAttempts: maxRetryAttempts,
            retryBaseDelay: retryBaseDelay,
            autoRestartDelay: autoRestartDelay,
            maxAutoRestarts: maxAutoRestarts,
            clock: clock,
        )
        suspension = ConversationSuspension(
            gracePeriod: suspendGracePeriod,
            clock: clock,
            onExpired: { [owner] in
                owner.owner?.handleHoldExpired()
            },
        )
        routeWatcher = RealtimeAudioRouteWatcher(
            audioSession: audioSession,
            playbackFailures: player.failures,
            onShouldStop: { [owner] in
                owner.owner?.stopForAudioRouteSafety()
            },
            onRouteChanged: { [owner] in
                owner.owner?.handleRouteChange()
            },
            onPlaybackFailure: { [owner] failure in
                owner.owner?.handlePlayerFailure(failure)
            },
        )
        owner.owner = self
    }

    var sessionGuard: RealtimeSessionGuard {
        runtime.sessionGuard
    }

    var snapshot: ConversationSessionSnapshot {
        snapshotState.withLock { $0 }
    }

    /// Protocol and lifecycle events, oldest first. Diagnostics for
    /// tests and DEBUG traces; release builds record nothing.
    var protocolEvents: [String] {
        runtime.diagnostics.events
    }

    private var operationGuard: RealtimeOperationGuard {
        runtime.operationGuard
    }

    // MARK: - Commands

    func start() async {
        if operationGuard.isDisposed {
            return
        }
        recovery.cancelAutoRestart()
        await startFlight.run(
            ifNeeded: { snapshot.sessionState.canStart },
        ) {
            await self.acquireAndStart()
        }
    }

    func stop() async {
        if operationGuard.isDisposed {
            return
        }
        await stopFlight.run(
            ifNeeded: { snapshot.sessionState.canStop },
        ) {
            await self.performStop()
        }
    }

    func changeVoice(_ voice: String) async {
        if operationGuard.isDisposed {
            return
        }
        if !snapshot.sessionState.isActive || snapshot.isReconfiguring {
            await relaunchFlight.join()
            return
        }
        let voiceId = WiroModelCatalog.voiceFieldId
        if parameters.value(for: voiceId) == voice {
            return
        }
        parameters.setValue(voice, for: voiceId)
        await relaunchFlight.run {
            await self.relaunch("voice_change")
        }
    }

    func suspend() async {
        if operationGuard.isDisposed {
            return
        }
        recovery.cancelAutoRestart()
        if snapshot.isSuspended || !snapshot.sessionState.isActive {
            return
        }
        if !suspension.holdsAnything
            || startFlight.isRunning
            || relaunchFlight.isRunning
        {
            await stop()
            return
        }
        let operationId = operationGuard.begin()
        runtime.taskLauncher.cancelPendingRequest()
        await silence(.fadeOut)
        await runtime.dropSession()
        if !operationGuard.isCurrent(operationId) {
            return
        }
        runtime.releaseLease()
        suspension.begin()
        runtime.record("conversation_held")
        publish(
            snapshot.copyWith(
                microphoneActive: false,
                isSuspended: true,
            ),
        )
    }

    func resume() async {
        if operationGuard.isDisposed || !snapshot.isSuspended {
            return
        }
        suspension.cancel()
        if suspension.hasLapsed {
            await endHeldSession("hold_expired")
            return
        }
        let outcome = await runtime.acquireLease(
            isStillWanted: { snapshot.isSuspended },
        )
        switch outcome {
        case .busy:
            await endHeldSession("hold_lost_to_another_session")
        case .superseded:
            return
        case .acquired:
            suspension.clear()
            await relaunchFlight.run {
                await self.relaunch(
                    "resume",
                    reuseTask: true,
                    prepareAudio: true,
                )
            }
        }
    }

    func setMuted(_ muted: Bool) {
        if operationGuard.isDisposed {
            return
        }
        recorder.setMuted(muted)
        if muted {
            turnTaking.noteMuted()
        }
        publish(
            snapshot.copyWith(
                microphoneActive: snapshot.sessionState == .streaming
                    && !muted,
                muted: muted,
            ),
        )
    }

    func setParameter(_ value: String, for id: String) {
        if operationGuard.isDisposed {
            return
        }
        parameters.setValue(value, for: id)
    }

    func interruptAssistant() {
        if operationGuard.isDisposed
            || snapshot.sessionState != .streaming
        {
            return
        }
        if turnTaking.interruptAssistant() {
            runtime.record("assistant_silenced_by_user")
        }
    }

    func openSystemSettings() async {
        if operationGuard.isDisposed {
            return
        }
        if !(await audioSession.openSystemSettings()) {
            runtime.record("system_settings_unavailable")
        }
    }

    func dispose() async {
        if operationGuard.isDisposed {
            return
        }
        runtime.dispose()
        micWatchdog.dispose()
        recovery.dispose()
        suspension.dispose()
        turnTaking.cancelHold()
        await routeWatcher.dispose()
        await stopCapture()
        await player.stop()
        await audioSession.deactivate()
        runtime.session?.sendSessionEnd()
        await runtime.taskLauncher.terminateBestEffort()
        await runtime.dropSession()
        await recorder.dispose()
        await player.dispose()
        runtime.releaseLease()
        turnTaking.dispose()
        snapshotSink.finish()
    }

    // MARK: - Starting

    /// The loading state is published before the wait for the slot so
    /// a second tap cannot start twice.
    private func acquireAndStart() async {
        let operationId = operationGuard.begin()
        publish(
            snapshot.copyWith(
                sessionState: .requestingPermission,
                errorMessage: .some(nil),
            ),
        )
        let outcome = await runtime.acquireLease(
            isStillWanted: { operationGuard.isCurrent(operationId) },
        )
        switch outcome {
        case .superseded:
            return
        case .busy:
            publish(
                snapshot.copyWith(
                    sessionState: .failure,
                    errorMessage: .some(WiroFailure.sessionBusy.message),
                ),
            )
        case .acquired:
            recovery.resetRetries()
            await startSession(isRetry: false)
        }
    }

    private func startSession(isRetry: Bool) async {
        let operationId = operationGuard.begin()
        if !isRetry {
            runtime.diagnostics.clear()
        }
        publish(
            snapshot.copyWith(
                sessionState: .requestingPermission,
                elapsed: isRetry ? nil : .zero,
                userTranscript: isRetry ? nil : "",
                aiTranscript: isRetry ? nil : "",
                microphoneActive: false,
                errorMessage: .some(nil),
                canOpenSystemSettings: false,
            ),
        )

        do {
            if !(await prepareAudio(operationId)) {
                return
            }
            publish(snapshot.copyWith(sessionState: .preparingAudio))
            publish(snapshot.copyWith(sessionState: .creatingTask))
            guard let runResult = try await launchTask(operationId)
            else {
                return
            }
            let connected = try await openSession(
                runResult,
                operationId,
            )
            if !connected {
                return
            }
            try await goLive(operationId, event: "conversation_stream_started")
        } catch {
            if operationGuard.isCurrent(operationId) {
                await fail(operationId, error)
            }
        }
    }

    /// Opens the microphone against a connected session and reports
    /// the conversation live. The player is started here too, so a
    /// relaunch that already has one running does not restart it.
    private func goLive(_ operationId: Int, event: String) async throws {
        let stream = try await recorder.start(.conversation)
        if !player.isPlaying {
            try await player.start()
        }
        if !operationGuard.isCurrent(operationId) {
            await recorder.stop()
            await player.stop()
            await runtime.session?.close()
            return
        }
        listenForPcm(stream, operationId)
        startElapsedTimer(operationId)
        runtime.record(event)
        publish(
            snapshot.copyWith(
                sessionState: .streaming,
                microphoneActive: !snapshot.muted,
                isReconfiguring: false,
            ),
        )
        watchdogOperationId = operationId
        micWatchdog.start()
    }

    private func launchTask(
        _ operationId: Int,
    ) async throws -> WiroRunResult? {
        try await runtime.taskLauncher.launch(
            model: model,
            parameters: parameters.requestSnapshot().jsonObject,
            isStillWanted: { [weak self] in
                self?.operationGuard.isCurrent(operationId) ?? false
            },
        )
    }

    /// Subscribes to a launched task. Returns false when the caller
    /// moved on mid-connect; throws when the socket refused.
    private func openSession(
        _ runResult: WiroRunResult,
        _ operationId: Int,
        userTranscript: String? = nil,
        aiTranscript: String? = nil,
    ) async throws -> Bool {
        let session = sessionFactory(
            runResult.taskId,
            runResult.taskToken,
        )
        runtime.attach(session)
        naturalCompletion = nil
        naturalCompletionRunning = false
        turnTaking.reset()
        session.addEventListener { [weak self] event in
            self?.handleEvent(event, operationId)
        }
        session.addErrorListener { [weak self] error in
            self?.failLater(operationId, error)
        }
        session.addDoneListener { [weak self] in
            self?.handleEventStreamDone(operationId)
        }
        publish(
            snapshot.copyWith(
                sessionState: .connectingSocket,
                userTranscript: userTranscript,
                aiTranscript: aiTranscript,
            ),
        )
        // Audio starts with `task_stream_ready`. The queue drops
        // chunks while the player is stopped, so it listens first.
        try await player.start()
        if !operationGuard.isCurrent(operationId) {
            await player.stop()
            await session.close()
            return false
        }
        let connection = Task { try await session.connect() }
        if operationGuard.isCurrent(operationId) {
            publish(snapshot.copyWith(sessionState: .waitingForStream))
        }
        do {
            try await connection.value
        } catch {
            await player.stop()
            throw error
        }
        if !operationGuard.isCurrent(operationId) {
            await player.stop()
            await session.close()
            return false
        }
        return true
    }

    private func prepareAudio(_ operationId: Int) async -> Bool {
        let preparation = await audioSession.prepare(.conversation)
        if !operationGuard.isCurrent(operationId) {
            await audioSession.deactivate()
            return false
        }
        if preparation == .ready {
            return true
        }
        await audioSession.deactivate()
        runtime.releaseLease()
        publish(
            snapshot.copyWith(
                sessionState: .failure,
                microphoneActive: false,
                isReconfiguring: false,
                isSuspended: false,
                errorMessage: .some(preparation.errorMessage),
                canOpenSystemSettings: preparation.needsSystemSettings,
            ),
        )
        return false
    }

    // MARK: - Stopping

    private func performStop() async {
        let operationId = operationGuard.begin()
        recovery.cancelAutoRestart()
        publish(
            snapshot.copyWith(
                sessionState: .stopping,
                microphoneActive: false,
                isReconfiguring: false,
            ),
        )
        runtime.taskLauncher.cancelPendingRequest()
        await silence(.dropQueued)
        await naturalCompletion?.value
        // The hardware is free from here on; only the protocol
        // wind-down remains. Holding the lease through the terminal
        // wait would block whichever feature the user already moved
        // on to for those seconds.
        runtime.releaseLease()

        let ending = await runtime.endSession()
        await startFlight.join()
        runtime.clearSession()
        naturalCompletion = nil
        if ending == .nothingToEnd {
            await runtime.taskLauncher.terminateBestEffort()
        } else {
            runtime.taskLauncher.release()
        }

        if !operationGuard.isCurrent(operationId) {
            return
        }
        // A slow confirmation is not news the user can act on: the
        // conversation is over and the server winds down an abandoned
        // task on its own. It stays in the diagnostics.
        runtime.record(
            ending == .unconfirmed ? "shutdown_timeout" : "session_stopped",
        )
        publish(
            snapshot.copyWith(
                sessionState: .completed,
                microphoneActive: false,
                isSuspended: false,
                errorMessage: .some(nil),
            ),
        )
    }

    /// The server ended the task on its own — a quiet conversation
    /// wound down, or a `task_error` — and the app follows suit
    /// rather than launching a replacement it was not asked for.
    private func completeNaturally(_ operationId: Int) async {
        if !operationGuard.isCurrent(operationId)
            || naturalCompletionRunning
        {
            return
        }
        naturalCompletionRunning = true
        await silence(.playOut)
        if !operationGuard.isCurrent(operationId) {
            naturalCompletionRunning = false
            return
        }
        let completionId = operationGuard.begin()
        await runtime.dropSession()
        naturalCompletion = nil
        naturalCompletionRunning = false
        runtime.taskLauncher.release()
        runtime.releaseLease()
        if !operationGuard.isCurrent(completionId) {
            return
        }
        publish(
            snapshot.copyWith(
                sessionState: .completed,
                microphoneActive: false,
                isReconfiguring: false,
            ),
        )
        if !stopFlight.isRunning {
            runtime.record("conversation_ended_remotely")
        }
    }

    private func endHeldSession(_ reason: String) async {
        suspension.clear()
        runtime.record(reason)
        await stop()
    }

    private func handleHoldExpired() {
        if operationGuard.isDisposed || !snapshot.isSuspended {
            return
        }
        Task { await self.endHeldSession("hold_expired") }
    }

    /// How playback ends when the session quiets down.
    private enum PlaybackEnding {
        /// Whatever is queued is dropped on the floor.
        case dropQueued
        /// The speaker fades and the queue is cleared.
        case fadeOut
        /// Queued audio plays to the end first.
        case playOut
    }

    /// Quiets everything that listens or speaks, in the order that
    /// keeps it clean: capture first so no chunk is sent into a
    /// closing socket, then playback, then the turn model that judged
    /// them, and the audio session last.
    private func silence(_ ending: PlaybackEnding) async {
        micWatchdog.stop()
        turnTaking.cancelHold()
        runtime.elapsedClock.stop()
        await stopCapture()
        switch ending {
        case .dropQueued:
            break
        case .fadeOut:
            player.flush()
        case .playOut:
            await player.complete()
        }
        await player.stop()
        turnTaking.reset()
        await audioSession.deactivate()
    }

    private func stopCapture() async {
        pcmTask?.cancel()
        pcmTask = nil
        await recorder.stop()
    }

    // MARK: - Relaunching

    /// Rebuilds the live conversation in place, keeping the transcript
    /// and the clock as they are.
    private func relaunch(
        _ reason: String,
        reuseTask: Bool = false,
        prepareAudio: Bool = false,
    ) async {
        let operationId = operationGuard.begin()
        let preservedUserTranscript = snapshot.userTranscript
        let preservedAiTranscript = snapshot.aiTranscript
        runtime.record("\(reason)_started")
        publish(
            snapshot.copyWith(
                sessionState: .creatingTask,
                microphoneActive: false,
                isReconfiguring: true,
                isSuspended: false,
            ),
        )

        do {
            await stopCapture()
            player.flush()
            turnTaking.reset()

            if prepareAudio, !(await self.prepareAudio(operationId)) {
                return
            }

            var reconnected = false
            if reuseTask {
                reconnected = try await reconnectToHeldTask(
                    operationId,
                    userTranscript: preservedUserTranscript,
                    aiTranscript: preservedAiTranscript,
                )
            }
            if !operationGuard.isCurrent(operationId) {
                return
            }

            if !reconnected {
                await closeActiveSessionForRelaunch()
                if !operationGuard.isCurrent(operationId) {
                    return
                }
                guard let runResult = try await launchTask(operationId)
                else {
                    return
                }
                let connected = try await openSession(
                    runResult,
                    operationId,
                    userTranscript: preservedUserTranscript,
                    aiTranscript: preservedAiTranscript,
                )
                if !connected {
                    return
                }
            }
            try await goLive(operationId, event: "\(reason)_completed")
        } catch {
            if operationGuard.isCurrent(operationId) {
                await fail(operationId, error)
            }
        }
    }

    /// Resubscribes to the task the app already holds. A new task is a
    /// new assistant with no memory of anything said so far, so this
    /// is tried first and a fresh launch only follows a refusal.
    private func reconnectToHeldTask(
        _ operationId: Int,
        userTranscript: String,
        aiTranscript: String,
    ) async throws -> Bool {
        guard let heldTask = runtime.taskLauncher.currentRunResult else {
            return false
        }
        runtime.taskLauncher.cancelPendingRequest()
        await runtime.dropSession()
        if !operationGuard.isCurrent(operationId) {
            return false
        }
        runtime.record("reconnect_attempted")
        do {
            let reconnected = try await withTimeout(reconnectTimeout) {
                try await self.openSession(
                    heldTask,
                    operationId,
                    userTranscript: userTranscript,
                    aiTranscript: aiTranscript,
                )
            }
            if reconnected {
                runtime.record("reconnect_accepted")
            }
            return reconnected
        } catch {
            runtime.record("reconnect_refused")
            await runtime.dropSession()
            return false
        }
    }

    private func closeActiveSessionForRelaunch() async {
        runtime.taskLauncher.cancelPendingRequest()
        if let session = runtime.session, !session.isClosed {
            session.sendSessionEnd()
        }
        await runtime.dropSession()
        await runtime.taskLauncher.terminateBestEffort()
    }

    // MARK: - Microphone

    private func listenForPcm(
        _ stream: AsyncThrowingStream<Data, Error>,
        _ operationId: Int,
    ) {
        pcmTask?.cancel()
        pcmTask = Task {
            do {
                for try await chunk in stream {
                    self.sendPcm(chunk, operationId)
                }
            } catch {
                self.failLater(operationId, error)
            }
        }
    }

    private func sendPcm(_ chunk: Data, _ operationId: Int) {
        if !operationGuard.isCurrent(operationId) {
            return
        }
        micWatchdog.markAlive()
        let gated = turnTaking.gate(chunk)
        let sent = runtime.session?.sendAudio(gated.gated) ?? false
        if !sent {
            failLater(operationId, WiroFailure.socketConnection)
            return
        }
        recovery.noteHealthy()
        turnTaking.noteSent(gated)
    }

    private func handleMicStall() {
        let operationId = watchdogOperationId
        if !operationGuard.isCurrent(operationId)
            || snapshot.sessionState != .streaming
        {
            return
        }
        if snapshot.muted {
            micWatchdog.markAlive()
            return
        }
        micWatchdog.stop()
        runtime.record("microphone_stalled")
        failLater(operationId, AudioFailure.capture)
    }

    // MARK: - Socket events

    private func handleEvent(
        _ event: RealtimeEvent,
        _ operationId: Int,
    ) {
        switch event {
        case .status(.ended), .status(.postprocessEnded):
            runtime.noteTerminalEvent()
        default:
            break
        }
        if !operationGuard.isCurrent(operationId) {
            return
        }

        switch event {
        case let .binary(bytes):
            queueAudio(bytes)
        case let .output(message):
            handleOutput(message)
        case .status(.streamEnded):
            runtime.record(event.wireType)
            finishAiTurn()
        case .status(.postprocessEnded), .error:
            runtime.record(event.wireType)
            scheduleNaturalCompletion(operationId)
        case .cancel:
            runtime.record(event.wireType)
            failLater(operationId, WiroFailure.cancelled)
        case .malformed:
            runtime.record(event.wireType)
            failLater(operationId, WiroFailure.realtimeProtocol)
        case .status, .unknown:
            runtime.record(event.wireType)
        }
    }

    private func scheduleNaturalCompletion(_ operationId: Int) {
        if naturalCompletion == nil {
            naturalCompletion = Task {
                await self.completeNaturally(operationId)
            }
        }
    }

    private func queueAudio(_ bytes: Data) {
        let outcome = turnTaking.acceptAssistantAudio(bytes)
        if outcome.flushedPreviousTurn {
            runtime.record("previous_turn_dropped")
        }
        if outcome.droppedChunk {
            runtime.record("audio_chunk_dropped")
        }
    }

    private func handleOutput(_ message: String) {
        switch Self.transcriptParser.parse(message) {
        case let .user(text):
            releaseInterruptedTurnIfNeeded()
            runtime.record("task_output")
            publish(snapshot.copyWith(userTranscript: text))
        case let .ai(text):
            if Self.startsANewAnswer(text, after: snapshot.aiTranscript) {
                releaseInterruptedTurnIfNeeded()
            }
            runtime.record("task_output")
            publish(snapshot.copyWith(aiTranscript: text))
        case nil:
            runtime.record("task_output")
        }
    }

    /// Whether an assistant transcript belongs to a turn other than
    /// the one whose text is on screen. The model dictates one turn
    /// cumulatively, so a continuation always extends the text it
    /// already sent; anything else is a fresh answer. An empty
    /// previous text proves nothing either way and is treated as a
    /// continuation, since a wrong release would let a cut turn's
    /// audio back through.
    static func startsANewAnswer(
        _ text: String,
        after previous: String,
    ) -> Bool {
        !previous.isEmpty && !text.hasPrefix(previous)
    }

    /// A barge-in has no wire message on this protocol: the model
    /// only learns of it from the microphone, and the cut turn's
    /// `task_stream_end` is not guaranteed to arrive before the new
    /// answer's audio. The server's own transcripts are the earliest
    /// proof it moved on — it heard the interruption, or it is
    /// dictating something new — so they lift the latch that would
    /// otherwise swallow the whole next answer.
    private func releaseInterruptedTurnIfNeeded() {
        if turnTaking.releaseInterruptedTurn() {
            runtime.record("interrupted_turn_released")
        }
    }

    private func finishAiTurn() {
        turnTaking.markTurnFinished()
        runtime.record("listening_resumed")
        publish(
            snapshot.copyWith(
                sessionState: .streaming,
                microphoneActive: !snapshot.muted,
            ),
        )
    }

    private func handleEventStreamDone(_ operationId: Int) {
        if operationGuard.isCurrent(operationId),
           !runtime.terminalReceived
        {
            runtime.record("socket_closed_remotely")
            failLater(operationId, WiroFailure.socketConnection)
        }
    }

    private func handlePlayerFailure(_ failure: AudioFailure) {
        if snapshot.sessionState.isActive {
            failLater(operationGuard.current, failure)
        }
    }

    private func stopForAudioRouteSafety() {
        if snapshot.sessionState.canStop {
            Task { await self.stop() }
        }
    }

    private func handleRouteChange() {
        if snapshot.sessionState.isActive {
            runtime.record("audio_route_changed")
        }
    }

    // MARK: - Failing

    /// Fails from a synchronous context — a socket or capture
    /// callback — once at most: a dead socket rejects fifty chunks a
    /// second, and the first rejection already supersedes the rest.
    private func failLater(_ operationId: Int, _ error: Error) {
        guard operationGuard.isCurrent(operationId) else {
            return
        }
        Task { await self.fail(operationId, error) }
    }

    private func fail(_ operationId: Int, _ error: Error) async {
        if !operationGuard.isCurrent(operationId) {
            return
        }
        let shouldRetry = recovery.shouldRetry(
            error,
            isReconfiguring: snapshot.isReconfiguring,
        )
        let isCancellation = (error as? WiroFailure)?.code == .cancelled
        let canReuseTask = shouldRetry
            && runtime.taskLauncher.currentRunResult != nil
            && !isCancellation
            && !runtime.terminalReceived
            && snapshot.sessionState == .streaming
        let failureId = operationGuard.begin()
        if !canReuseTask {
            await runtime.taskLauncher.terminateBestEffort()
        }
        runtime.taskLauncher.cancelPendingRequest()
        await silence(.dropQueued)
        await runtime.dropSession()
        naturalCompletion = nil
        naturalCompletionRunning = false
        if !operationGuard.isCurrent(failureId) {
            return
        }
        if shouldRetry {
            await retry(failureId, reuseTask: canReuseTask)
            return
        }
        runtime.releaseLease()
        runtime.record(
            "failure:\(Self.failureMapper.code(for: error))",
        )
        publish(
            snapshot.copyWith(
                sessionState: .failure,
                microphoneActive: false,
                isReconfiguring: false,
                errorMessage: .some(
                    Self.failureMapper.message(for: error),
                ),
                canOpenSystemSettings: false,
            ),
        )
        if recovery.isRecoverable(error) {
            scheduleAutoRestart()
        }
    }

    private func retry(_ failureId: Int, reuseTask: Bool) async {
        recovery.noteRetryScheduled()
        runtime.record(
            "retry_scheduled:\(recovery.retryAttempt)/"
                + "\(recovery.maxRetryAttempts)",
        )
        publish(
            snapshot.copyWith(
                sessionState: .creatingTask,
                microphoneActive: false,
                isReconfiguring: false,
                errorMessage: .some(nil),
            ),
        )
        try? await clock.sleep(for: recovery.nextRetryDelay)
        if !operationGuard.isCurrent(failureId) {
            return
        }
        runtime.record("retry_started:\(recovery.retryAttempt)")
        if reuseTask {
            await relaunch("reconnect", reuseTask: true, prepareAudio: true)
        } else {
            await startSession(isRetry: true)
        }
    }

    /// A failing backend gets a bounded number of unattended restarts;
    /// once spent, the toolbar start item is tapped again.
    private func scheduleAutoRestart() {
        if operationGuard.isDisposed {
            return
        }
        let armedState = snapshot.sessionState
        let scheduled = recovery.scheduleAutoRestart { [weak self] in
            guard let self,
                  !self.operationGuard.isDisposed,
                  self.snapshot.sessionState == armedState
            else {
                return
            }
            Task { await self.start() }
        }
        if scheduled {
            runtime.record("auto_restart_scheduled")
        }
    }

    // MARK: - Reporting

    private func publish(_ next: ConversationSessionSnapshot) {
        if operationGuard.isDisposed {
            return
        }
        let changed = snapshotState.withLock { current in
            if current == next {
                return false
            }
            current = next
            return true
        }
        if changed {
            snapshotSink.yield(next)
        }
    }

    private func startElapsedTimer(_ operationId: Int) {
        runtime.startElapsedTimer(
            operationId,
            base: snapshot.elapsed,
        ) { [weak self] total in
            guard let self else {
                return
            }
            self.publish(self.snapshot.copyWith(elapsed: total))
            self.enforceSessionLimit(total)
        }
    }

    private func enforceSessionLimit(_ elapsed: Duration) {
        let limit = maxSessionDuration
        if limit <= .zero || elapsed < limit || stopFlight.isRunning {
            return
        }
        runtime.record("session_limit_reached")
        Task { await self.stop() }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        let clock = clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}
