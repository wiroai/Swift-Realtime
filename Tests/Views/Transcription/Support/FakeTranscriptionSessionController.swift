import Foundation
@testable import SwiftRealtime

/// Keeps the snapshot stream open after `dispose` so a test can prove
/// the view model stopped applying events rather than the controller
/// shutting the stream down.
final class FakeTranscriptionSessionController:
    TranscriptionSessionController, @unchecked Sendable
{
    private let continuation:
        AsyncStream<TranscriptionSessionSnapshot>.Continuation
    let snapshots: AsyncStream<TranscriptionSessionSnapshot>

    var snapshot = TranscriptionSessionSnapshot()
    var startCalls = 0
    var stopCalls = 0
    var disposeCalls = 0
    var clearCalls = 0
    var openSettingsCalls = 0
    var muteRequests: [Bool] = []
    var setParameterCalls: [(id: String, value: String)] = []

    let model = WiroModelCatalog.voxtralMiniRealtime
    var parameters = ModelParameterValues(
        fields: WiroModelCatalog.voxtralMiniRealtime.firstPassFields,
    )
    let sessionGuard = RealtimeSessionGuard()

    init() {
        let stream = AsyncStream.makeStream(
            of: TranscriptionSessionSnapshot.self,
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

    func setMuted(_ muted: Bool) {
        muteRequests.append(muted)
    }

    func setParameter(_ value: String, for id: String) {
        setParameterCalls.append((id: id, value: value))
        parameters.setValue(value, for: id)
    }

    func clearTranscript() {
        clearCalls += 1
    }

    func openSystemSettings() async {
        openSettingsCalls += 1
    }

    func dispose() async {
        disposeCalls += 1
    }

    func publish(_ next: TranscriptionSessionSnapshot) {
        snapshot = next
        continuation.yield(next)
    }
}
