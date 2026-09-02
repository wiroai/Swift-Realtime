import Foundation
import os
@testable import SwiftRealtime

/// Wires a transcription session against in-memory audio and
/// network doubles.
final class TranscriptionTestDependencies: @unchecked Sendable {
    let audioSession: FakeRealtimeAudioSession
    let apiClient = FakeWiroApiClient()
    let recorder = FakeConversationRecorder()
    let session: FakeTranscriptionSession
    let sessionGuard = RealtimeSessionGuard()

    init(
        preparationResult: AudioPreparationResult = .ready,
        completeSessionEnd: Bool = true,
    ) {
        audioSession = FakeRealtimeAudioSession(
            preparationResult: preparationResult,
        )
        session = FakeTranscriptionSession(
            completeSessionEnd: completeSessionEnd,
        )
        apiClient.nextRunResult = WiroRunResult(
            taskId: "task-id",
            taskToken: "task-token",
        )
    }

    func createService() -> SpeechToTextSessionService {
        SpeechToTextSessionService(
            audioSession: audioSession,
            apiClient: apiClient,
            sessionFactory: { [session] _, _ in session },
            recorder: recorder,
            sessionGuard: sessionGuard,
            terminalTimeout: .zero,
        )
    }
}

final class FakeTranscriptionSession:
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
    private let completeSessionEnd: Bool
    private var ready = false
    private var closed = false

    init(completeSessionEnd: Bool = true) {
        self.completeSessionEnd = completeSessionEnd
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
        if let error = connectError {
            connectError = nil
            throw error
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
