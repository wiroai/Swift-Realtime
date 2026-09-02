import Foundation
import os

/// Runs microphone capture and the realtime transcription session.
///
/// The service reports itself only through `snapshots` and never
/// touches view state. There is no playback, barge-in, or reconnect:
/// leaving the tab ends the billed task.
final class SpeechToTextSessionService:
    TranscriptionSessionController, @unchecked Sendable
{
    let audioSession: any RealtimeAudioSession
    let sessionFactory: RealtimeSessionFactory
    let recorder: any PcmAudioRecorder
    let model: ModelDefinition
    private(set) var parameters: ModelParameterValues

    private static let transcriptPrefix = "TRANSCRIPT_USER:"
    private static let failureMapper = RealtimeFailureMapper(
        fallbackMessage:
        "The transcription session could not be completed.",
    )

    let snapshots: AsyncStream<TranscriptionSessionSnapshot>
    private let snapshotSink: AsyncStream<
        TranscriptionSessionSnapshot,
    >.Continuation
    private let snapshotState = OSAllocatedUnfairLock(
        initialState: TranscriptionSessionSnapshot(),
    )

    private let runtime: RealtimeSessionRuntime
    private let routeWatcher: RealtimeAudioRouteWatcher
    private let startFlight = SingleFlight()
    private let stopFlight = SingleFlight()

    private var confirmedTranscript = ""
    private var liveSegment = ""
    private var pcmTask: Task<Void, Never>?
    private var naturalCompletion: Task<Void, Never>?
    private var naturalCompletionRunning = false

    init(
        audioSession: any RealtimeAudioSession,
        apiClient: any WiroApiClient,
        sessionFactory: @escaping RealtimeSessionFactory,
        recorder: any PcmAudioRecorder,
        sessionGuard: RealtimeSessionGuard,
        model: ModelDefinition =
            WiroModelCatalog.voxtralMiniRealtime,
        terminalTimeout: Duration = .seconds(3),
    ) {
        self.audioSession = audioSession
        self.sessionFactory = sessionFactory
        self.recorder = recorder
        self.model = model
        parameters = ModelParameterValues(
            fields: model.firstPassFields,
        )
        let stream = AsyncStream<TranscriptionSessionSnapshot>
            .makeStream()
        snapshots = stream.stream
        snapshotSink = stream.continuation
        runtime = RealtimeSessionRuntime(
            owner: .transcription,
            apiClient: apiClient,
            sessionGuard: sessionGuard,
            terminalTimeout: terminalTimeout,
        )
        let owner = WeakOwner<SpeechToTextSessionService>()
        // Nothing plays back here; the watcher only needs a stream
        // that has already ended.
        let noPlaybackFailures = AsyncStream<AudioFailure>.makeStream()
        noPlaybackFailures.continuation.finish()
        routeWatcher = RealtimeAudioRouteWatcher(
            audioSession: audioSession,
            playbackFailures: noPlaybackFailures.stream,
            onShouldStop: { [owner] in
                owner.owner?.stopForAudioRouteSafety()
            },
            onRouteChanged: { [owner] in
                owner.owner?.handleRouteChange()
            },
            onPlaybackFailure: { _ in },
        )
        owner.owner = self
    }

    var sessionGuard: RealtimeSessionGuard {
        runtime.sessionGuard
    }

    var snapshot: TranscriptionSessionSnapshot {
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

    func setMuted(_ muted: Bool) {
        if operationGuard.isDisposed {
            return
        }
        recorder.setMuted(muted)
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

    func clearTranscript() {
        if operationGuard.isDisposed || snapshot.sessionState.isActive {
            return
        }
        confirmedTranscript = ""
        liveSegment = ""
        publish(snapshot.copyWith(transcript: ""))
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
        await routeWatcher.dispose()
        await stopCapture()
        await audioSession.deactivate()
        runtime.session?.sendSessionEnd()
        await runtime.taskLauncher.terminateBestEffort()
        await runtime.dropSession()
        await recorder.dispose()
        runtime.releaseLease()
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
            await startSession()
        }
    }

    private func startSession() async {
        let operationId = operationGuard.begin()
        runtime.diagnostics.clear()
        confirmedTranscript = ""
        liveSegment = ""
        publish(
            snapshot.copyWith(
                sessionState: .requestingPermission,
                elapsed: .zero,
                transcript: "",
                microphoneActive: false,
                muted: false,
                errorMessage: .some(nil),
                canOpenSystemSettings: false,
            ),
        )
        recorder.setMuted(false)

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
            if !(try await openSession(runResult, operationId)) {
                return
            }

            let stream = try await recorder.start(.transcription)
            if !operationGuard.isCurrent(operationId) {
                await recorder.stop()
                await runtime.session?.close()
                return
            }
            listenForPcm(stream, operationId)
            runtime.startElapsedTimer(operationId) { [weak self] elapsed in
                guard let self else {
                    return
                }
                self.publish(self.snapshot.copyWith(elapsed: elapsed))
            }
            runtime.record("microphone_stream_started")
            publish(
                snapshot.copyWith(
                    sessionState: .streaming,
                    microphoneActive: true,
                ),
            )
        } catch {
            if operationGuard.isCurrent(operationId) {
                await fail(operationId, error)
            }
        }
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
    ) async throws -> Bool {
        let session = sessionFactory(
            runResult.taskId,
            runResult.taskToken,
        )
        runtime.attach(session)
        naturalCompletion = nil
        naturalCompletionRunning = false
        session.addEventListener { [weak self] event in
            self?.handleEvent(event, operationId)
        }
        session.addErrorListener { [weak self] error in
            self?.failLater(operationId, error)
        }
        session.addDoneListener { [weak self] in
            self?.handleEventStreamDone(operationId)
        }
        publish(snapshot.copyWith(sessionState: .connectingSocket))
        let connection = Task { try await session.connect() }
        if operationGuard.isCurrent(operationId) {
            publish(snapshot.copyWith(sessionState: .waitingForStream))
        }
        try await connection.value
        if !operationGuard.isCurrent(operationId) {
            await session.close()
            return false
        }
        return true
    }

    private func prepareAudio(_ operationId: Int) async -> Bool {
        let preparation = await audioSession.prepare(.transcription)
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
                errorMessage: .some(preparation.errorMessage),
                canOpenSystemSettings: preparation.needsSystemSettings,
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
                microphoneActive: false,
            ),
        )

        runtime.taskLauncher.cancelPendingRequest()
        runtime.elapsedClock.stop()
        await stopCapture()
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
        naturalCompletion = nil
        runtime.taskLauncher.release()

        if !operationGuard.isCurrent(operationId) {
            return
        }
        // A slow confirmation is not news the user can act on: the
        // microphone is off, the transcript is already on screen, and
        // the server winds down an abandoned task on its own. It stays
        // in the diagnostics.
        runtime.record(
            ending == .unconfirmed ? "shutdown_timeout" : "session_stopped",
        )
        publish(
            snapshot.copyWith(
                sessionState: .completed,
                microphoneActive: false,
                errorMessage: .some(nil),
            ),
        )
    }

    /// The server ended the task on its own and the app follows suit.
    private func completeNaturally(_ operationId: Int) async {
        if !operationGuard.isCurrent(operationId)
            || naturalCompletionRunning
        {
            return
        }
        naturalCompletionRunning = true
        await stopCapture()
        await audioSession.deactivate()
        if !operationGuard.isCurrent(operationId) {
            naturalCompletionRunning = false
            return
        }
        let completionId = operationGuard.begin()
        runtime.elapsedClock.stop()
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
            ),
        )
    }

    private func stopCapture() async {
        pcmTask?.cancel()
        pcmTask = nil
        await recorder.stop()
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
        if !(runtime.session?.sendAudio(chunk) ?? false) {
            failLater(operationId, WiroFailure.socketConnection)
        }
    }

    // MARK: - Socket events

    private func handleEvent(
        _ event: RealtimeEvent,
        _ operationId: Int,
    ) {
        if case .status(.postprocessEnded) = event {
            runtime.noteTerminalEvent()
        }
        if !operationGuard.isCurrent(operationId) {
            return
        }

        switch event {
        case let .output(message):
            handleOutput(message)
        case .status(.streamEnded):
            runtime.record(event.wireType)
            Task { await self.handleStreamEnded(operationId) }
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
        case .malformed, .binary:
            runtime.record(event.wireType)
            failLater(operationId, WiroFailure.realtimeProtocol)
        case .status, .unknown:
            runtime.record(event.wireType)
        }
    }

    /// Folds one transcript event into the running text.
    ///
    /// The model streams each utterance progressively and starts
    /// over at the next one, so a raw replace would leave only the
    /// final fragment of the last sentence on screen. An event that
    /// extends the live utterance refines it in place; an event that
    /// does not is a new utterance, and the finished one moves into
    /// the confirmed text for good.
    private func handleOutput(_ message: String) {
        runtime.record("task_output")
        guard message.hasPrefix(Self.transcriptPrefix) else {
            return
        }
        let text = String(
            message.dropFirst(Self.transcriptPrefix.count),
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return
        }
        if text.hasPrefix(liveSegment) || liveSegment.isEmpty {
            liveSegment = text
        } else if !liveSegment.hasPrefix(text) {
            confirmedTranscript = joinedTranscript
            liveSegment = text
        }
        publish(snapshot.copyWith(transcript: joinedTranscript))
    }

    private var joinedTranscript: String {
        if confirmedTranscript.isEmpty {
            return liveSegment
        }
        return "\(confirmedTranscript) \(liveSegment)"
    }

    private func handleStreamEnded(_ operationId: Int) async {
        await stopCapture()
        await audioSession.deactivate()
        if !operationGuard.isCurrent(operationId) {
            return
        }
        publish(
            snapshot.copyWith(
                sessionState: .stopping,
                microphoneActive: false,
            ),
        )
    }

    private func handleEventStreamDone(_ operationId: Int) {
        if operationGuard.isCurrent(operationId),
           !runtime.terminalReceived
        {
            failLater(operationId, WiroFailure.socketConnection)
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
        let failureId = operationGuard.begin()
        runtime.taskLauncher.cancelPendingRequest()
        await runtime.taskLauncher.terminateBestEffort()
        runtime.elapsedClock.stop()
        await stopCapture()
        await audioSession.deactivate()
        await runtime.dropSession()
        naturalCompletion = nil
        naturalCompletionRunning = false
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
                microphoneActive: false,
                errorMessage: .some(
                    Self.failureMapper.message(for: error),
                ),
            ),
        )
    }

    // MARK: - Reporting

    private func publish(_ next: TranscriptionSessionSnapshot) {
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
