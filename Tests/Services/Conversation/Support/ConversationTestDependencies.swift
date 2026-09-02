import Foundation
import os
@testable import SwiftRealtime

/// Wires a conversation session against in-memory audio and network
/// doubles.
final class ConversationTestDependencies: @unchecked Sendable {
    let audioSession: FakeRealtimeAudioSession
    let apiClient = FakeWiroApiClient()
    let recorder = FakeConversationRecorder()
    let player = FakeConversationPlayer()
    let session = FakeConversationSession()
    let sessionGuard = RealtimeSessionGuard()
    let subscribedTaskTokens: OSAllocatedUnfairLock<[String]> =
        OSAllocatedUnfairLock(initialState: [])

    init(
        preparationResult: AudioPreparationResult = .ready,
        runErrors: [Error] = [],
    ) {
        audioSession = FakeRealtimeAudioSession(
            preparationResult: preparationResult,
        )
        apiClient.runErrors = runErrors
        apiClient.nextRunResult = WiroRunResult(
            taskId: "task-id",
            taskToken: "task-token",
        )
    }

    var taskTokens: [String] {
        subscribedTaskTokens.withLock { $0 }
    }

    func createService(
        maxRetryAttempts: Int = 0,
        retryBaseDelay: Duration = .zero,
        micStallTimeout: Duration = .seconds(3),
        autoRestartDelay: Duration = .seconds(5),
        maxAutoRestarts: Int = 2,
        maxSessionDuration: Duration = .zero,
        suspendGracePeriod: Duration =
            ConversationConfig.suspendGracePeriod,
        parameterOverrides: [String: String] =
            ConversationConfig.parameters,
    ) -> SpeechToSpeechSessionService {
        SpeechToSpeechSessionService(
            audioSession: audioSession,
            apiClient: apiClient,
            sessionFactory: { [session, subscribedTaskTokens] _, token in
                subscribedTaskTokens.withLock { $0.append(token) }
                return session
            },
            recorder: recorder,
            player: player,
            sessionGuard: sessionGuard,
            model: ConversationConfig.model,
            parameters: ConversationConfig.parameterValues(
                overrides: parameterOverrides,
            ),
            suspendGracePeriod: suspendGracePeriod,
            maxSessionDuration: maxSessionDuration,
            terminalTimeout: .zero,
            maxRetryAttempts: maxRetryAttempts,
            retryBaseDelay: retryBaseDelay,
            micStallTimeout: micStallTimeout,
            autoRestartDelay: autoRestartDelay,
            maxAutoRestarts: maxAutoRestarts,
        )
    }
}

final class FakeConversationRecorder:
    PcmAudioRecorder, @unchecked Sendable
{
    private var continuation: AsyncThrowingStream<Data, Error>
        .Continuation?
    private var recording = false
    private var muted = false

    var startCalls = 0
    var stopCalls = 0
    var disposeCalls = 0

    var isRecording: Bool { recording }
    var isMuted: Bool { muted }

    func start(
        _: PcmCaptureProfile,
    ) async throws -> AsyncThrowingStream<Data, Error> {
        startCalls += 1
        recording = true
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
    }

    func stop() async {
        guard recording else {
            return
        }
        stopCalls += 1
        recording = false
        continuation?.finish()
        continuation = nil
    }

    func dispose() async {
        disposeCalls += 1
        await stop()
    }

    func emit(_ bytes: Data) {
        if recording, !muted {
            continuation?.yield(bytes)
        }
    }
}

final class FakeConversationPlayer:
    PcmAudioPlayer, @unchecked Sendable
{
    let failures: AsyncStream<AudioFailure>
    private let failureContinuation:
        AsyncStream<AudioFailure>.Continuation
    private(set) var fedChunks: [Data] = []
    var startCalls = 0
    var completeCalls = 0
    var stopCalls = 0
    var flushCalls = 0
    var disposeCalls = 0
    private var playing = false
    private var enabled = true

    var isPlaying: Bool { playing }
    var isEnabled: Bool { enabled }

    init() {
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
        flushCalls += 1
        fedChunks.removeAll()
    }

    func complete() async {
        completeCalls += 1
        playing = false
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
    }

    func dispose() async {
        disposeCalls += 1
        playing = false
        failureContinuation.finish()
    }
}

final class FakeConversationSession:
    RealtimeSessionClient, @unchecked Sendable
{
    private var eventListeners: [@Sendable (RealtimeEvent) -> Void] = []
    private var errorListeners: [@Sendable (Error) -> Void] = []
    private var doneListeners: [@Sendable () -> Void] = []
    private(set) var sentAudio: [Data] = []
    var connectCalls = 0
    var sessionEndCalls = 0
    var closeCalls = 0
    var connectError: Error?
    private var ready = false
    private var closed = false

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
        if let error = connectError {
            connectError = nil
            throw error
        }
        closed = false
        ready = true
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
        emit(.status(.ended))
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

func conversationPcm(
    amplitude: Int16,
    milliseconds: Int = 20,
) -> Data {
    let sampleCount = AudioConstants.sampleRateHz * milliseconds
        / 1000
    var data = Data(count: sampleCount * 2)
    data.withUnsafeMutableBytes { raw in
        let buffer = raw.bindMemory(to: Int16.self)
        for index in 0..<sampleCount {
            buffer[index] = amplitude
        }
    }
    return data
}
