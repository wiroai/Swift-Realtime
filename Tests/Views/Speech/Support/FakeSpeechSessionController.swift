import Foundation
@testable import SwiftRealtime

/// Keeps the snapshot stream open after `dispose` so a test can prove
/// the view model stopped applying events rather than the controller
/// shutting the stream down.
final class FakeSpeechSessionController:
    SpeechSessionController, @unchecked Sendable
{
    private let continuation:
        AsyncStream<SpeechSessionSnapshot>.Continuation
    let snapshots: AsyncStream<SpeechSessionSnapshot>

    var snapshot = SpeechSessionSnapshot(
        selectedModel: WiroModelCatalog.mossTtsRealtime,
    )
    var startCalls = 0
    var stopCalls = 0
    var disposeCalls = 0
    var selectCalls = 0
    var setParameterCalls: [(id: String, value: String)] = []
    var prompt = ""

    var parameters = ModelParameterValues(
        fields: WiroModelCatalog.mossTtsRealtime.firstPassFields,
    )
    let sessionGuard = RealtimeSessionGuard()

    var commandCalls: Int {
        selectCalls + startCalls + stopCalls
    }

    init() {
        let stream = AsyncStream.makeStream(
            of: SpeechSessionSnapshot.self,
        )
        snapshots = stream.stream
        continuation = stream.continuation
    }

    func selectModel(_: ModelDefinition) {
        selectCalls += 1
    }

    func setParameter(_ value: String, for id: String) {
        setParameterCalls.append((id: id, value: value))
        parameters.setValue(value, for: id)
    }

    func start() async {
        startCalls += 1
    }

    func stop() async {
        stopCalls += 1
    }

    func dispose() async {
        disposeCalls += 1
    }

    func publish(_ next: SpeechSessionSnapshot) {
        snapshot = next
        continuation.yield(next)
    }
}
