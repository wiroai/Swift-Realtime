import Foundation
import os
@testable import SwiftRealtime

/// Wires a speech session against in-memory audio and network
/// doubles.
final class SpeechTestDependencies: @unchecked Sendable {
    let audioSession: FakeRealtimeAudioSession
    let apiClient = FakeWiroApiClient()
    let player: FakeSpeechPlayer
    let session: FakeSpeechSession
    let sessionGuard = RealtimeSessionGuard()

    init(
        preparationResult: AudioPreparationResult = .ready,
        completeSessionEnd: Bool = true,
        holdComplete: Bool = false,
        sessionConnectFailures: Int = 0,
    ) {
        audioSession = FakeRealtimeAudioSession(
            preparationResult: preparationResult,
        )
        player = FakeSpeechPlayer(holdComplete: holdComplete)
        session = FakeSpeechSession(
            completeSessionEnd: completeSessionEnd,
            connectFailures: sessionConnectFailures,
        )
        apiClient.nextRunResult = WiroRunResult(
            taskId: "task-id",
            taskToken: "task-token",
        )
    }

    func createService(
        model: ModelDefinition = WiroModelCatalog.mossTtsRealtime,
    ) -> TextToSpeechSessionService {
        TextToSpeechSessionService(
            audioSession: audioSession,
            apiClient: apiClient,
            sessionFactory: { [session] _, _ in session },
            player: player,
            sessionGuard: sessionGuard,
            model: model,
            terminalTimeout: .zero,
            connectRetryDelay: .zero,
        )
    }
}

final class FakeSpeechPlayer: PcmAudioPlayer, @unchecked Sendable {
    let failures: AsyncStream<AudioFailure>
    private let failureContinuation:
        AsyncStream<AudioFailure>.Continuation
    private(set) var fedChunks: [Data] = []
    var startCalls = 0
    var completeCalls = 0
    var stopCalls = 0
    var disposeCalls = 0
    private var playing = false
    private var enabled = true
    private let holdComplete: Bool
    private var completeGate: CheckedContinuation<Void, Never>?

    var isPlaying: Bool { playing }
    var isEnabled: Bool { enabled }

    init(holdComplete: Bool = false) {
        self.holdComplete = holdComplete
        let stream = AsyncStream<AudioFailure>.makeStream()
        failures = stream.stream
        failureContinuation = stream.continuation
    }

    func start() async throws {
        startCalls += 1
        playing = true
    }

    func enqueue(_ chunk: Data) async {
        _ = tryEnqueue(chunk)
    }

    func tryEnqueue(_ chunk: Data) -> Bool {
        if playing, enabled {
            fedChunks.append(chunk)
            return true
        }
        return false
    }

    func flush() {
        fedChunks.removeAll()
    }

    func complete() async {
        completeCalls += 1
        if holdComplete {
            await withCheckedContinuation { continuation in
                completeGate = continuation
            }
        }
        playing = false
    }

    func releaseComplete() {
        completeGate?.resume()
        completeGate = nil
    }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
    }

    func stop() async {
        guard playing else {
            return
        }
        stopCalls += 1
        playing = false
        completeGate?.resume()
        completeGate = nil
    }

    func dispose() async {
        disposeCalls += 1
        playing = false
        failureContinuation.finish()
    }

    func emitFailure() {
        failureContinuation.yield(.playback)
    }
}

final class FakeSpeechSession:
    RealtimeSessionClient, @unchecked Sendable
{
    private var eventListeners: [@Sendable (RealtimeEvent) -> Void] = []
    private var errorListeners: [@Sendable (Error) -> Void] = []
    private var doneListeners: [@Sendable () -> Void] = []
    private(set) var sentAudio: [Data] = []
    var connectCalls = 0
    var sessionEndCalls = 0
    var closeCalls = 0
    var connectFailures: Int
    private let completeSessionEnd: Bool
    private var ready = false
    private var closed = false

    init(
        completeSessionEnd: Bool = true,
        connectFailures: Int = 0,
    ) {
        self.completeSessionEnd = completeSessionEnd
        self.connectFailures = connectFailures
    }

    var isReady: Bool { ready && !closed }
    var isClosed: Bool { closed }

    func addEventListener(
        _ listener: @escaping @Sendable (RealtimeEvent) -> Void,
    ) {
        eventListeners.append(listener)
    }

    func addErrorListener(
        _ listener: @escaping @Sendable (Error) -> Void,
    ) {
        errorListeners.append(listener)
    }

    func addDoneListener(
        _ listener: @escaping @Sendable () -> Void,
    ) {
        doneListeners.append(listener)
    }

    func connect() async throws {
        connectCalls += 1
        if connectFailures > 0 {
            connectFailures -= 1
            throw WiroFailure.socketConnection
        }
        closed = false
        ready = true
        sessionEndCalls = 0
    }

    func sendAudio(_ pcmBytes: Data) -> Bool {
        guard isReady else {
            return false
        }
        sentAudio.append(pcmBytes)
        return true
    }

    func sendSessionEnd() {
        if closed || sessionEndCalls > 0 {
            return
        }
        sessionEndCalls += 1
        if completeSessionEnd {
            emit(.status(.postprocessEnded))
        }
    }

    func close() async {
        if closed {
            return
        }
        closeCalls += 1
        closed = true
        ready = false
    }

    func emit(_ event: RealtimeEvent) {
        for listener in eventListeners {
            listener(event)
        }
    }

    func emitError(_ error: Error) {
        for listener in errorListeners {
            listener(error)
        }
    }
}
