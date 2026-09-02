import Foundation
@testable import SwiftRealtime

/// Keeps the snapshot stream open after `dispose` so a test can prove
/// the view model stopped applying events rather than the controller
/// shutting the stream down.
final class FakeConversationSessionController:
    ConversationSessionController, @unchecked Sendable
{
    private let continuation:
        AsyncStream<ConversationSessionSnapshot>.Continuation
    let snapshots: AsyncStream<ConversationSessionSnapshot>

    var snapshot = ConversationSessionSnapshot()
    var startCalls = 0
    var stopCalls = 0
    var disposeCalls = 0
    var interruptCalls = 0
    var screenTouchCalls = 0
    var suspendCalls = 0
    var resumeCalls = 0
    var openSettingsCalls = 0
    var muteRequests: [Bool] = []
    var changeVoiceCalls: [String] = []
    var setParameterCalls: [(id: String, value: String)] = []

    let model = WiroModelCatalog.gptRealtimeMini
    var parameters = ConversationConfig.parameterValues()
    let sessionGuard = RealtimeSessionGuard()

    init() {
        let stream = AsyncStream.makeStream(
            of: ConversationSessionSnapshot.self,
        )
        snapshots = stream.stream
        continuation = stream.continuation
    }

    func start() async {
        startCalls += 1
    }

    func stop() async {
        stopCalls += 1
    }

    func changeVoice(_ voice: String) async {
        changeVoiceCalls.append(voice)
        parameters.setValue(voice, for: ConversationFields.voiceId)
    }

    func suspend() async {
        suspendCalls += 1
    }

    func resume() async {
        resumeCalls += 1
    }

    func setMuted(_ muted: Bool) {
        muteRequests.append(muted)
    }

    func setParameter(_ value: String, for id: String) {
        setParameterCalls.append((id: id, value: value))
        parameters.setValue(value, for: id)
    }

    func interruptAssistant() {
        interruptCalls += 1
    }

    func noteScreenTouch() {
        screenTouchCalls += 1
    }

    func openSystemSettings() async {
        openSettingsCalls += 1
    }

    func dispose() async {
        disposeCalls += 1
    }

    func publish(_ next: ConversationSessionSnapshot) {
        snapshot = next
        continuation.yield(next)
    }
}
