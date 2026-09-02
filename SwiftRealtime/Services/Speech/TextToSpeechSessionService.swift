import Foundation
import os

/// Owns task creation, realtime audio playback, and session
/// termination.
///
/// The service reports itself only through `snapshots` and never
/// touches view state. A TTS model can spin up cold and drop the
/// subscriber socket while it does; the session resubscribes to the
/// task it already has instead of launching a second billed run.
final class TextToSpeechSessionService:
    SpeechSessionController, @unchecked Sendable
{
    let audioSession: any RealtimeAudioSession
    let sessionFactory: RealtimeSessionFactory
    let player: any PcmAudioPlayer
    let connectRetryDelay: Duration
    let maxConnectAttempts: Int
    private(set) var parameters: ModelParameterValues

    /// What the screen shows when Play is tapped on an empty prompt.
    static let emptyPromptMessage = "Enter text to synthesize."
    /// Where the prompt goes for a model whose schema does not say.
    private static let defaultPromptFieldId = "prompt"
    private static let failureMapper = RealtimeFailureMapper(
        fallbackMessage:
        "The speech session could not be completed.",
    )

    let snapshots: AsyncStream<SpeechSessionSnapshot>
    private let snapshotSink: AsyncStream<
        SpeechSessionSnapshot,
    >.Continuation
    private let snapshotState: OSAllocatedUnfairLock<
        SpeechSessionSnapshot,
    >

    private let runtime: RealtimeSessionRuntime
    private let routeWatcher: RealtimeAudioRouteWatcher
    private let startFlight = SingleFlight()
    private let stopFlight = SingleFlight()

    private var selectedModel: ModelDefinition
    private var playbackCompletion: Task<Void, Never>?
    private var naturalCompletion: Task<Void, Never>?
    private var naturalCompletionRunning = false
    private var connectingSession = false
    private var listenerGeneration = 0

    init(
        audioSession: any RealtimeAudioSession,
        apiClient: any WiroApiClient,
        sessionFactory: @escaping RealtimeSessionFactory,
        player: any PcmAudioPlayer,
        sessionGuard: RealtimeSessionGuard,
        model: ModelDefinition = WiroModelCatalog.mossTtsRealtime,
        terminalTimeout: Duration = .seconds(3),
        connectRetryDelay: Duration = .seconds(4),
        maxConnectAttempts: Int = 8,
    ) {
        self.audioSession = audioSession
        self.sessionFactory = sessionFactory
        self.player = player
        self.connectRetryDelay = connectRetryDelay
        self.maxConnectAttempts = maxConnectAttempts
        selectedModel = model
        parameters = ModelParameterValues(
            fields: model.firstPassFields,
        )
        snapshotState = OSAllocatedUnfairLock(
            initialState: SpeechSessionSnapshot(selectedModel: model),
        )
        let stream = AsyncStream<SpeechSessionSnapshot>.makeStream()
        snapshots = stream.stream
        snapshotSink = stream.continuation
        runtime = RealtimeSessionRuntime(
            owner: .speech,
            apiClient: apiClient,
            sessionGuard: sessionGuard,
            terminalTimeout: terminalTimeout,
        )
        let owner = WeakOwner<TextToSpeechSessionService>()
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

    var snapshot: SpeechSessionSnapshot {
        snapshotState.withLock { $0 }
    }

    /// Protocol and lifecycle events, oldest first. Diagnostics for
    /// tests and DEBUG traces; release builds record nothing.
    var protocolEvents: [String] {
        runtime.diagnostics.events
    }

    var prompt: String {
        get { parameters.value(for: promptFieldId) ?? "" }
        set { parameters.setValue(newValue, for: promptFieldId) }
    }

    private var promptFieldId: String {
        selectedModel.promptFieldId ?? Self.defaultPromptFieldId
    }

    private var operationGuard: RealtimeOperationGuard {
        runtime.operationGuard
    }

    // MARK: - Commands

    func selectModel(_ model: ModelDefinition) {
        if operationGuard.isDisposed
            || snapshot.sessionState.isActive
            || model.direction != .textToSpeech
        {
            return
        }
        selectedModel = model
        parameters = ModelParameterValues(
            fields: model.firstPassFields,
        )
        publish(
            snapshot.copyWith(
                selectedModel: model,
                errorMessage: .some(nil),
            ),
        )
    }

    func setParameter(_ value: String, for id: String) {
        if operationGuard.isDisposed {
            return
        }
        parameters.setValue(value, for: id)
    }

    func start() async {
        if operationGuard.isDisposed || !snapshot.sessionState.canStart {
            return
        }
        let trimmed = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        if trimmed.isEmpty {
            publish(
                snapshot.copyWith(
                    sessionState: .failure,
                    errorMessage: .some(Self.emptyPromptMessage),
                ),
            )
            return
        }
        await startFlight.run(
            ifNeeded: { snapshot.sessionState.canStart },
        ) {
            await self.acquireAndStart(trimmed)
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

    func dispose() async {
        if operationGuard.isDisposed {
            return
        }
        runtime.dispose()
        await routeWatcher.dispose()
        await player.stop()
        await audioSession.deactivate()
        runtime.session?.sendSessionEnd()
        await runtime.taskLauncher.terminateBestEffort()
        await runtime.dropSession()
        await player.dispose()
        clearCompletions()
        runtime.releaseLease()
        snapshotSink.finish()
    }

    // MARK: - Starting

    /// The loading state is published before the wait for the slot so
    /// a second tap cannot start twice.
    private func acquireAndStart(_ prompt: String) async {
        let operationId = operationGuard.begin()
        publish(
            snapshot.copyWith(
                sessionState: .preparingAudio,
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
            await startSession(prompt)
        }
    }

    private func startSession(_ prompt: String) async {
        let operationId = operationGuard.begin()
        runtime.diagnostics.clear()
        publish(
            snapshot.copyWith(
                sessionState: .preparingAudio,
                elapsed: .zero,
                isPlaying: false,
                errorMessage: .some(nil),
            ),
        )

        do {
            if !(await prepareAudio(operationId)) {
                return
            }
            publish(snapshot.copyWith(sessionState: .creatingTask))
            guard let runResult = try await launchTask(
                prompt,
                operationId,
            ) else {
                if operationGuard.isCurrent(operationId) {
                    publish(snapshot.copyWith(sessionState: .idle))
                }
                return
            }
            let session = try await connectToTask(
                runResult,
                operationId,
            )
            if session == nil || !operationGuard.isCurrent(operationId)
            {
                await player.stop()
                await session?.close()
                return
            }
            runtime.startElapsedTimer(operationId) { [weak self] elapsed in
                guard let self else {
                    return
                }
                self.publish(self.snapshot.copyWith(elapsed: elapsed))
            }
            runtime.record("playback_stream_started")
            publish(snapshot.copyWith(sessionState: .streaming))
        } catch {
            if operationGuard.isCurrent(operationId) {
                await fail(operationId, error)
            }
        }
    }

    /// Connects and subscribes to the launched task, retrying
    /// recoverable socket drops a cold model outlives.
    ///
    /// Returns nil when the caller moved on mid-attempt; throws
    /// once the retry budget is spent or the failure is one a
    /// retry cannot help. A ready-wait that expires is different:
    /// the socket replays nothing to a late subscriber, so that
    /// failure is not retried against the same task.
    private func connectToTask(
        _ runResult: WiroRunResult,
        _ operationId: Int,
    ) async throws -> (any RealtimeSessionClient)? {
        var attempt = 0
        while true {
            attempt += 1
            listenerGeneration += 1
            let generation = listenerGeneration
            let session = sessionFactory(
                runResult.taskId,
                runResult.taskToken,
            )
            runtime.attach(session)
            clearCompletions()
            connectingSession = true
            session.addEventListener { [weak self] event in
                self?.handleEvent(event, operationId, generation)
            }
            session.addErrorListener { [weak self] error in
                self?.handleEventError(error, operationId, generation)
            }
            session.addDoneListener { [weak self] in
                self?.handleEventStreamDone(operationId, generation)
            }
            publish(snapshot.copyWith(sessionState: .connectingSocket))
            // Audio starts with `task_stream_ready`. The queue drops
            // chunks while the player is stopped, so playback must
            // already be listening when we subscribe.
            try await player.start()
            if !operationGuard.isCurrent(operationId) {
                await player.stop()
                await session.close()
                return nil
            }
            let connection = Task<WiroFailure?, Error> {
                do {
                    try await session.connect()
                    return nil
                } catch let failure as WiroFailure {
                    return failure
                }
            }
            if operationGuard.isCurrent(operationId) {
                publish(
                    snapshot.copyWith(sessionState: .waitingForStream),
                )
            }
            let error: WiroFailure?
            do {
                error = try await connection.value
            } catch {
                connectingSession = false
                await runtime.dropSession()
                throw error
            }
            connectingSession = false
            guard let error else {
                return session
            }
            await runtime.dropSession()
            let canRetry = isRecoverableConnectFailure(error)
                && attempt < maxConnectAttempts
                && operationGuard.isCurrent(operationId)
            guard canRetry else {
                throw error
            }
            runtime.record("socket_reconnect:\(attempt)")
            if connectRetryDelay > .zero {
                try? await Task.sleep(for: connectRetryDelay)
            }
            if !operationGuard.isCurrent(operationId) {
                return nil
            }
        }
    }

    private func isRecoverableConnectFailure(
        _ failure: WiroFailure,
    ) -> Bool {
        switch failure.code {
        case .socketConnection, .socketConnectTimeout:
            true
        default:
            false
        }
    }

    private func launchTask(
        _ prompt: String,
        _ operationId: Int,
    ) async throws -> WiroRunResult? {
        var request = parameters.requestSnapshot()
        request[promptFieldId] = .string(prompt)
        return try await runtime.taskLauncher.launch(
            model: selectedModel,
            parameters: request.jsonObject,
            isStillWanted: { [weak self] in
                self?.operationGuard.isCurrent(operationId) ?? false
            },
        )
    }

    private func prepareAudio(_ operationId: Int) async -> Bool {
        let preparation = await audioSession.prepare(.speech)
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
                errorMessage: .some(preparation.errorMessage),
            ),
        )
        return false
    }

    // MARK: - Stopping

    private func performStop() async {
        let operationId = operationGuard.begin()
        publish(
            snapshot.copyWith(
                sessionState: .stopping,
                isPlaying: false,
            ),
        )

        runtime.taskLauncher.cancelPendingRequest()
        runtime.elapsedClock.stop()
        await player.stop()
        await naturalCompletion?.value
        await audioSession.deactivate()
        // The hardware is free from here on; only the protocol
        // wind-down remains. Holding the lease through the terminal
        // wait would block whichever feature the user already moved
        // on to for those seconds.
        runtime.releaseLease()

        let ending = await runtime.endSession()
        await startFlight.join()
        runtime.clearSession()
        clearCompletions()
        runtime.taskLauncher.release()

        if !operationGuard.isCurrent(operationId) {
            return
        }
        // A slow confirmation is not news the user can act on: the
        // playback is over and the server winds down an abandoned
        // task on its own. It stays in the diagnostics.
        runtime.record(
            ending == .unconfirmed ? "shutdown_timeout" : "session_stopped",
        )
        publish(
            snapshot.copyWith(
                sessionState: .completed,
                isPlaying: false,
                errorMessage: .some(nil),
            ),
        )
    }

    /// The server ended the task on its own; playback drains before
    /// the app follows suit.
    private func completeNaturally(_ operationId: Int) async {
        if !operationGuard.isCurrent(operationId)
            || naturalCompletionRunning
        {
            return
        }
        naturalCompletionRunning = true
        finishPlaybackOnce(operationId)
        await playbackCompletion?.value
        if !operationGuard.isCurrent(operationId) {
            naturalCompletionRunning = false
            return
        }
        let completionId = operationGuard.begin()
        runtime.elapsedClock.stop()
        await audioSession.deactivate()
        await runtime.dropSession()
        clearCompletions()
        runtime.taskLauncher.release()
        runtime.releaseLease()
        if !operationGuard.isCurrent(completionId) {
            return
        }
        publish(
            snapshot.copyWith(
                sessionState: .completed,
                isPlaying: false,
            ),
        )
    }

    private func clearCompletions() {
        playbackCompletion = nil
        naturalCompletion = nil
        naturalCompletionRunning = false
    }

    // MARK: - Socket events

    private func handleEvent(
        _ event: RealtimeEvent,
        _ operationId: Int,
        _ generation: Int,
    ) {
        if generation != listenerGeneration {
            return
        }
        if case .status(.postprocessEnded) = event {
            runtime.noteTerminalEvent()
        }
        if !operationGuard.isCurrent(operationId) {
            return
        }

        switch event {
        case let .binary(bytes):
            queueAudio(bytes)
        case .status(.streamEnded):
            runtime.record(event.wireType)
            publish(snapshot.copyWith(sessionState: .stopping))
            finishPlaybackOnce(operationId)
        case .status(.postprocessEnded):
            runtime.record(event.wireType)
            if naturalCompletion == nil {
                naturalCompletion = Task {
                    await self.completeNaturally(operationId)
                }
            }
        case .error:
            // Interim stderr from the model; the session is still
            // alive.
            runtime.record(event.wireType)
        case .cancel:
            runtime.record(event.wireType)
            failLater(operationId, WiroFailure.cancelled)
        case .malformed:
            runtime.record(event.wireType)
            failLater(operationId, WiroFailure.realtimeProtocol)
        case .output, .status, .unknown:
            runtime.record(event.wireType)
        }
    }

    private func queueAudio(_ bytes: Data) {
        if !snapshot.isPlaying {
            publish(snapshot.copyWith(isPlaying: true))
        }
        if !player.tryEnqueue(bytes) {
            runtime.record("audio_chunk_dropped")
        }
    }

    /// Plays the queue out to the end, once per session.
    private func finishPlaybackOnce(_ operationId: Int) {
        if playbackCompletion == nil {
            playbackCompletion = Task {
                await self.finishPlayback(operationId)
            }
        }
    }

    private func finishPlayback(_ operationId: Int) async {
        if !operationGuard.isCurrent(operationId) {
            return
        }
        await player.complete()
        if operationGuard.isCurrent(operationId) {
            publish(snapshot.copyWith(isPlaying: false))
        }
    }

    private func handleEventError(
        _ error: Error,
        _ operationId: Int,
        _ generation: Int,
    ) {
        if generation != listenerGeneration || connectingSession {
            return
        }
        failLater(operationId, error)
    }

    private func handleEventStreamDone(
        _ operationId: Int,
        _ generation: Int,
    ) {
        if generation != listenerGeneration || connectingSession {
            return
        }
        if !runtime.terminalReceived {
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

    /// Fails from a synchronous callback once at most; the first
    /// failure already supersedes the rest.
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
        let failureId = operationGuard.begin()
        runtime.taskLauncher.cancelPendingRequest()
        await runtime.taskLauncher.terminateBestEffort()
        runtime.elapsedClock.stop()
        await player.stop()
        await audioSession.deactivate()
        await runtime.dropSession()
        clearCompletions()
        runtime.releaseLease()
        if !operationGuard.isCurrent(failureId) {
            return
        }
        runtime.record(
            "failure:\(Self.failureMapper.code(for: error))",
        )
        publish(
            snapshot.copyWith(
                sessionState: .failure,
                isPlaying: false,
                errorMessage: .some(
                    Self.failureMapper.message(for: error),
                ),
            ),
        )
    }

    // MARK: - Reporting

    private func publish(_ next: SpeechSessionSnapshot) {
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
}
