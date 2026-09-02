import XCTest
@testable import SwiftRealtime

final class RealtimeTaskLauncherTests: XCTestCase {
    private var apiClient: FakeWiroApiClient!
    private var launcher: RealtimeTaskLauncher!

    override func setUp() {
        super.setUp()
        apiClient = FakeWiroApiClient()
        launcher = RealtimeTaskLauncher(apiClient)
    }

    private func launch(
        wanted: Bool = true,
    ) async throws -> WiroRunResult? {
        try await launcher.launch(
            model: WiroModelCatalog.gptRealtimeMini,
            parameters: ["sampleRate": 24000],
            isStillWanted: { wanted },
        )
    }

    func testReturnsTheTaskAndForwardsTheRequestParameters() async throws {
        let runResult = try await launch()

        XCTAssertEqual(runResult?.taskId, "task-1")
        XCTAssertEqual(apiClient.runCalls, 1)
        XCTAssertEqual(
            apiClient.lastParameters?["sampleRate"] as? Int,
            24000,
        )
        XCTAssertEqual(
            apiClient.lastModel?.modelSlug,
            WiroModelCatalog.gptRealtimeMini.modelSlug,
        )
    }

    func testPassesACancellationTheCallerCanLaterAbort() async throws {
        _ = try await launch()

        XCTAssertNotNil(apiClient.lastCancellation)
    }

    func testTerminatesATaskThatArrivesAfterTheCallerMovedOn() async throws {
        let runResult = try await launch(wanted: false)

        XCTAssertNil(runResult)
        XCTAssertEqual(apiClient.terminatedTaskIds, ["task-1"])
    }

    func testAStaleTaskIsNotTerminatedTwiceByALaterTeardown() async throws {
        _ = try await launch(wanted: false)

        await launcher.terminateBestEffort()

        XCTAssertEqual(apiClient.terminatedTaskIds, ["task-1"])
    }

    func testTerminateBestEffortTearsDownTheLiveTaskExactlyOnce()
        async throws
    {
        _ = try await launch()

        await launcher.terminateBestEffort()
        await launcher.terminateBestEffort()

        XCTAssertEqual(apiClient.terminatedTaskIds, ["task-1"])
    }

    func testReleaseForgetsTheTaskWithoutTerminatingIt() async throws {
        _ = try await launch()

        launcher.release()
        await launcher.terminateBestEffort()

        XCTAssertTrue(apiClient.terminatedTaskIds.isEmpty)
    }

    func testCancelPendingRequestAbortsAnInFlightRequest() async throws {
        apiClient.holdRunModel = true
        let launcher = launcher!
        let pending = Task {
            try await launcher.launch(
                model: WiroModelCatalog.gptRealtimeMini,
                parameters: ["sampleRate": 24000],
                isStillWanted: { true },
            )
        }
        await apiClient.waitUntilHolding()

        launcher.cancelPendingRequest()

        XCTAssertEqual(apiClient.lastCancellation?.isCancelled, true)

        apiClient.completeRunModel()
        _ = try await pending.value
    }

    func testACompletedLaunchLeavesNoCancellationToAbort() async throws {
        _ = try await launch()

        launcher.cancelPendingRequest()

        XCTAssertEqual(apiClient.lastCancellation?.isCancelled, false)
    }

    func testTeardownIsSafeWhenNothingWasEverLaunched() async {
        launcher.release()
        await launcher.terminateBestEffort()
        launcher.cancelPendingRequest()
        XCTAssertTrue(apiClient.terminatedTaskIds.isEmpty)
    }
}
