import XCTest
@testable import SwiftRealtime

@MainActor
final class SpeechToTextViewModelTests: XCTestCase {
    func testTakesTheFixedModelFromTheSession() async {
        let harness = makeHarness()

        XCTAssertEqual(
            harness.viewModel.model,
            harness.controller.model,
        )
        await harness.viewModel.dispose()
    }

    func testAdoptsASessionThatIsAlreadyTranscribing() async {
        let controller = FakeTranscriptionSessionController()
        controller.snapshot = TranscriptionSessionSnapshot(
            sessionState: .streaming,
            transcript: "in progress",
        )
        let viewModel = SpeechToTextViewModel(
            sessionService: controller,
        )

        XCTAssertEqual(viewModel.state.sessionState, .streaming)
        XCTAssertEqual(viewModel.state.transcript, "in progress")
        await viewModel.dispose()
    }

    func testProjectsEveryDrawnSnapshotFieldOntoViewState() async {
        let harness = makeHarness()

        harness.controller.publish(
            TranscriptionSessionSnapshot(
                sessionState: .streaming,
                elapsed: .seconds(7),
                transcript: "hello",
                muted: true,
                errorMessage: "boom",
                canOpenSystemSettings: true,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.sessionState == .streaming
        }

        let state = harness.viewModel.state
        XCTAssertEqual(state.sessionState, .streaming)
        XCTAssertEqual(state.elapsed, .seconds(7))
        XCTAssertEqual(state.transcript, "hello")
        XCTAssertTrue(state.muted)
        XCTAssertEqual(state.errorMessage, "boom")
        XCTAssertTrue(state.canOpenSystemSettings)
        XCTAssertTrue(state.showsSystemSettingsAlert)
        await harness.viewModel.dispose()
    }

    func testClearingAnErrorMessagePropagatesTheNull() async {
        let harness = makeHarness()
        harness.controller.publish(
            TranscriptionSessionSnapshot(errorMessage: "boom"),
        )
        await waitFor(harness.viewModel) {
            $0.errorMessage == "boom"
        }

        harness.controller.publish(TranscriptionSessionSnapshot())
        await waitFor(harness.viewModel) { $0.errorMessage == nil }

        XCTAssertNil(harness.viewModel.state.errorMessage)
        await harness.viewModel.dispose()
    }

    func testCommandsAreDelegatedToTheSession() async {
        let harness = makeHarness()

        await harness.viewModel.start()
        await harness.viewModel.stop()
        harness.viewModel.setMuted(true)
        harness.viewModel.clearTranscript()
        await harness.viewModel.openSystemSettings()

        XCTAssertEqual(harness.controller.startCalls, 1)
        XCTAssertEqual(harness.controller.stopCalls, 1)
        XCTAssertEqual(harness.controller.muteRequests, [true])
        XCTAssertEqual(harness.controller.clearCalls, 1)
        XCTAssertEqual(harness.controller.openSettingsCalls, 1)
        await harness.viewModel.dispose()
    }

    func testIdleAccuracyChangeWritesTheParameter() async {
        let harness = makeHarness()

        harness.viewModel.selectAccuracy("accurate")

        XCTAssertEqual(
            harness.controller.setParameterCalls.map(\.value),
            ["accurate"],
        )
        XCTAssertEqual(harness.viewModel.accuracy, "accurate")
        await harness.viewModel.dispose()
    }

    func testSettingsAlertIsEdgeTriggered() async {
        let harness = makeHarness()
        harness.controller.publish(
            TranscriptionSessionSnapshot(
                canOpenSystemSettings: true,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.showsSystemSettingsAlert
        }

        harness.viewModel.dismissSystemSettingsAlert()
        XCTAssertFalse(
            harness.viewModel.state.showsSystemSettingsAlert,
        )
        XCTAssertTrue(harness.viewModel.state.canOpenSystemSettings)

        harness.controller.publish(
            TranscriptionSessionSnapshot(
                canOpenSystemSettings: true,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.canOpenSystemSettings
        }
        XCTAssertFalse(
            harness.viewModel.state.showsSystemSettingsAlert,
        )

        harness.controller.publish(TranscriptionSessionSnapshot())
        await waitFor(harness.viewModel) {
            !$0.canOpenSystemSettings
        }
        harness.controller.publish(
            TranscriptionSessionSnapshot(
                canOpenSystemSettings: true,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.showsSystemSettingsAlert
        }
        await harness.viewModel.dispose()
    }

    func testAnotherFeatureHoldingTheMicBlocksStart() async {
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
        let controller = FakeTranscriptionSessionController()
        let viewModel = SpeechToTextViewModel(
            sessionService: controller,
        )
        await viewModel.dispose()

        controller.publish(
            TranscriptionSessionSnapshot(transcript: "late"),
        )
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(controller.disposeCalls, 1)
        XCTAssertTrue(viewModel.state.transcript.isEmpty)
    }

    private func makeHarness() -> (
        controller: FakeTranscriptionSessionController,
        viewModel: SpeechToTextViewModel,
    ) {
        let controller = FakeTranscriptionSessionController()
        let viewModel = SpeechToTextViewModel(
            sessionService: controller,
        )
        return (controller, viewModel)
    }

    private func waitFor(
        _ viewModel: SpeechToTextViewModel,
        _ condition: (SpeechToTextState) -> Bool,
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
