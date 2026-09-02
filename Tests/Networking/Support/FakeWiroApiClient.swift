import Foundation
@testable import SwiftRealtime

final class FakeWiroApiClient: WiroApiClient, @unchecked Sendable {
    var runCalls = 0
    var lastModel: ModelDefinition?
    var lastParameters: [String: Any]?
    var lastCancellation: WiroRequestCancellation?
    var terminatedTaskIds: [String] = []
    var terminateCalls = 0
    var holdRunModel = false
    var runErrors: [Error] = []
    var nextRunResult = WiroRunResult(
        taskId: "task-1",
        taskToken: "token-1",
    )
    private(set) var isWaiting = false

    private var gate: CheckedContinuation<Void, Never>?

    func completeRunModel() {
        let gate = gate
        self.gate = nil
        isWaiting = false
        gate?.resume()
    }

    func waitUntilHolding() async {
        for _ in 0..<100 {
            if isWaiting {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func createCancellation() -> WiroRequestCancellation {
        let cancellation = WiroRequestCancellation()
        lastCancellation = cancellation
        return cancellation
    }

    func runModel(
        model: ModelDefinition,
        parameters: [String: Any],
        cancellation: WiroRequestCancellation?,
    ) async throws -> WiroRunResult {
        runCalls += 1
        lastModel = model
        lastParameters = parameters
        if !runErrors.isEmpty {
            throw runErrors.removeFirst()
        }
        if holdRunModel {
            await withCheckedContinuation { continuation in
                isWaiting = true
                gate = continuation
            }
        }
        return nextRunResult
    }

    func terminateTaskBestEffort(
        taskId: String,
        taskToken: String,
    ) async {
        terminateCalls += 1
        terminatedTaskIds.append(taskId)
    }
}
