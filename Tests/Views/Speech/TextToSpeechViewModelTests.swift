import XCTest
@testable import SwiftRealtime

@MainActor
final class TextToSpeechViewModelTests: XCTestCase {
    func testAppliesTheCurrentSnapshotInTheConstructor() async {
        let controller = FakeSpeechSessionController()
        controller.snapshot = SpeechSessionSnapshot(
            selectedModel: WiroModelCatalog.voxcpm2,
            sessionState: .streaming,
            isPlaying: true,
        )
        let viewModel = TextToSpeechViewModel(
            sessionService: controller,
        )

        XCTAssertEqual(
            viewModel.state.selectedModel,
            WiroModelCatalog.voxcpm2,
        )
        XCTAssertEqual(viewModel.state.sessionState, .streaming)
        await viewModel.dispose()
    }

    func testProjectsEveryDrawnSnapshotField() async {
        let harness = makeHarness()

        harness.controller.publish(
            SpeechSessionSnapshot(
                selectedModel: WiroModelCatalog.voxcpm2,
                sessionState: .streaming,
                elapsed: .seconds(4),
                isPlaying: true,
                errorMessage: "error",
            ),
        )
        await waitFor(harness.viewModel) {
            $0.sessionState == .streaming
        }

        let state = harness.viewModel.state
        XCTAssertEqual(state.selectedModel, WiroModelCatalog.voxcpm2)
        XCTAssertEqual(state.sessionState, .streaming)
        XCTAssertEqual(state.elapsed, .seconds(4))
        XCTAssertEqual(state.errorMessage, "error")
        await harness.viewModel.dispose()
    }

    func testDelegatesCommandsAndServiceGetters() async {
        let harness = makeHarness()

        harness.viewModel.selectModel(WiroModelCatalog.voxcpm2)
        await harness.viewModel.start()
        await harness.viewModel.stop()
        harness.viewModel.setParameter("3.0", for: "cfgValue")

        XCTAssertEqual(harness.controller.selectCalls, 1)
        XCTAssertEqual(harness.controller.startCalls, 1)
        XCTAssertEqual(harness.controller.stopCalls, 1)
        XCTAssertEqual(
            harness.controller.setParameterCalls.map(\.value),
            ["3.0"],
        )
        XCTAssertTrue(
            harness.viewModel.parameters == harness.controller.parameters,
        )
        XCTAssertTrue(
            harness.viewModel.sessionGuard
                === harness.controller.sessionGuard,
        )
        await harness.viewModel.dispose()
    }

    func testPromptReadsAndWritesThroughTheSession() async {
        let harness = makeHarness()

        harness.viewModel.prompt = "Speak this"

        XCTAssertEqual(harness.controller.prompt, "Speak this")
        XCTAssertEqual(harness.viewModel.prompt, "Speak this")
        await harness.viewModel.dispose()
    }

    func testAnotherFeatureHoldingTheSessionBlocksStart() async {
        let harness = makeHarness()
        let lease = harness.controller.sessionGuard.acquire(
            .conversation,
        )
        XCTAssertNotNil(lease)
        XCTAssertFalse(harness.viewModel.canStart)

        harness.controller.sessionGuard.release(lease!)
        XCTAssertTrue(harness.viewModel.canStart)
        await harness.viewModel.dispose()
    }

    func testDisposeReleasesTheSessionAndStopsListening() async {
        let controller = FakeSpeechSessionController()
        let viewModel = TextToSpeechViewModel(
            sessionService: controller,
        )
        await viewModel.dispose()

        controller.publish(
            SpeechSessionSnapshot(
                selectedModel: WiroModelCatalog.mossTtsRealtime,
                sessionState: .streaming,
            ),
        )
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(controller.disposeCalls, 1)
        XCTAssertEqual(viewModel.state.sessionState, .idle)
    }

    private func makeHarness() -> (
        controller: FakeSpeechSessionController,
        viewModel: TextToSpeechViewModel,
    ) {
        let controller = FakeSpeechSessionController()
        let viewModel = TextToSpeechViewModel(
            sessionService: controller,
        )
        return (controller, viewModel)
    }

    private func waitFor(
        _ viewModel: TextToSpeechViewModel,
        _ condition: (TextToSpeechState) -> Bool,
    ) async {
        for _ in 0..<100 {
            if condition(viewModel.state) {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("view model did not reach the expected state")
    }
}
