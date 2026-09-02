import XCTest
@testable import SwiftRealtime

@MainActor
final class SpeechToSpeechViewModelTests: XCTestCase {
    func testAdoptsASessionThatIsAlreadyMidConversation() async {
        let controller = FakeConversationSessionController()
        controller.snapshot = ConversationSessionSnapshot(
            sessionState: .streaming,
            muted: true,
        )
        let viewModel = SpeechToSpeechViewModel(
            sessionService: controller,
        )

        XCTAssertEqual(viewModel.state.sessionState, .streaming)
        XCTAssertTrue(viewModel.state.muted)
        await viewModel.dispose()
    }

    func testScreenTouchesReachTheSessionOnlyWhileLive() async {
        let controller = FakeConversationSessionController()
        let viewModel = SpeechToSpeechViewModel(
            sessionService: controller,
        )
        viewModel.noteScreenTouch()
        XCTAssertEqual(controller.screenTouchCalls, 0)

        controller.publish(
            ConversationSessionSnapshot(sessionState: .streaming),
        )
        await waitFor(viewModel) { $0.sessionState == .streaming }
        viewModel.noteScreenTouch()
        XCTAssertEqual(controller.screenTouchCalls, 1)
        await viewModel.dispose()
    }

    func testProjectsOntoViewStateWhatTheScreenDraws() async {
        let harness = makeHarness()

        harness.controller.publish(
            ConversationSessionSnapshot(
                sessionState: .streaming,
                elapsed: .seconds(7),
                userTranscript: "hello",
                aiTranscript: "hi there",
                muted: true,
                isReconfiguring: true,
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
        XCTAssertEqual(state.userTranscript, "hello")
        XCTAssertEqual(state.aiTranscript, "hi there")
        XCTAssertTrue(state.muted)
        XCTAssertTrue(state.isReconfiguring)
        XCTAssertEqual(state.errorMessage, "boom")
        XCTAssertTrue(state.canOpenSystemSettings)
        XCTAssertTrue(state.showsSystemSettingsAlert)
        await harness.viewModel.dispose()
    }

    func testClearingAnErrorMessagePropagatesTheNull() async {
        let harness = makeHarness()
        harness.controller.publish(
            ConversationSessionSnapshot(errorMessage: "boom"),
        )
        await waitFor(harness.viewModel) {
            $0.errorMessage == "boom"
        }

        harness.controller.publish(ConversationSessionSnapshot())
        await waitFor(harness.viewModel) { $0.errorMessage == nil }

        XCTAssertNil(harness.viewModel.state.errorMessage)
        await harness.viewModel.dispose()
    }

    func testStartRaisesReportsConnectingAndGoingLiveLowersIt() async {
        let harness = makeHarness()
        XCTAssertFalse(harness.viewModel.state.reportsConnecting)

        await harness.viewModel.start()
        XCTAssertTrue(harness.viewModel.state.reportsConnecting)

        harness.controller.publish(
            ConversationSessionSnapshot(
                sessionState: .creatingTask,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.sessionState == .creatingTask
        }
        XCTAssertTrue(harness.viewModel.state.reportsConnecting)
        XCTAssertTrue(harness.viewModel.state.showsConnecting)
        XCTAssertEqual(
            harness.viewModel.displayedStage,
            .connecting,
        )

        harness.controller.publish(
            ConversationSessionSnapshot(
                sessionState: .streaming,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.sessionState == .streaming
        }
        XCTAssertFalse(harness.viewModel.state.reportsConnecting)
        XCTAssertFalse(harness.viewModel.state.showsConnecting)
        XCTAssertEqual(harness.viewModel.displayedStage, .live)
        await harness.viewModel.dispose()
    }

    func testAFailedStartAlsoLowersReportsConnecting() async {
        let harness = makeHarness()
        await harness.viewModel.start()

        harness.controller.publish(
            ConversationSessionSnapshot(
                sessionState: .failure,
                errorMessage: "boom",
            ),
        )
        await waitFor(harness.viewModel) {
            $0.sessionState == .failure
        }

        XCTAssertFalse(harness.viewModel.state.reportsConnecting)
        XCTAssertEqual(harness.viewModel.displayedStage, .failed)
        await harness.viewModel.dispose()
    }

    func testASessionConnectingOnItsOwnRaisesNoReportsConnecting() async {
        let harness = makeHarness()

        harness.controller.publish(
            ConversationSessionSnapshot(
                sessionState: .connectingSocket,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.sessionState == .connectingSocket
        }

        XCTAssertFalse(harness.viewModel.state.reportsConnecting)
        XCTAssertFalse(harness.viewModel.state.showsConnecting)
        XCTAssertEqual(harness.viewModel.displayedStage, .live)
        await harness.viewModel.dispose()
    }

    func testSettingsAlertIsEdgeTriggered() async {
        let harness = makeHarness()
        harness.controller.publish(
            ConversationSessionSnapshot(
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
            ConversationSessionSnapshot(
                canOpenSystemSettings: true,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.canOpenSystemSettings
        }
        XCTAssertFalse(
            harness.viewModel.state.showsSystemSettingsAlert,
        )

        harness.controller.publish(ConversationSessionSnapshot())
        await waitFor(harness.viewModel) {
            !$0.canOpenSystemSettings
        }
        harness.controller.publish(
            ConversationSessionSnapshot(
                canOpenSystemSettings: true,
            ),
        )
        await waitFor(harness.viewModel) {
            $0.showsSystemSettingsAlert
        }
        await harness.viewModel.dispose()
    }

    func testCommandsAreDelegatedToTheSession() async {
        let harness = makeHarness()

        await harness.viewModel.start()
        await harness.viewModel.stop()
        harness.viewModel.setMuted(true)
        harness.viewModel.interruptAssistant()
        await harness.viewModel.suspend()
        await harness.viewModel.resume()
        await harness.viewModel.openSystemSettings()

        XCTAssertEqual(harness.controller.startCalls, 1)
        XCTAssertEqual(harness.controller.stopCalls, 1)
        XCTAssertEqual(harness.controller.muteRequests, [true])
        XCTAssertEqual(harness.controller.interruptCalls, 1)
        XCTAssertEqual(harness.controller.suspendCalls, 1)
        XCTAssertEqual(harness.controller.resumeCalls, 1)
        XCTAssertEqual(harness.controller.openSettingsCalls, 1)
        await harness.viewModel.dispose()
    }

    func testIdleVoiceChangeWritesTheParameter() async {
        let harness = makeHarness()

        await harness.viewModel.selectVoice("cedar")

        XCTAssertEqual(
            harness.controller.setParameterCalls.map(\.value),
            ["cedar"],
        )
        XCTAssertTrue(harness.controller.changeVoiceCalls.isEmpty)
        XCTAssertEqual(harness.viewModel.voice, "cedar")
        await harness.viewModel.dispose()
    }

    func testLiveVoiceChangeGoesThroughChangeVoice() async {
        let harness = makeHarness()
        harness.controller.publish(
            ConversationSessionSnapshot(sessionState: .streaming),
        )
        await waitFor(harness.viewModel) {
            $0.sessionState == .streaming
        }

        await harness.viewModel.selectVoice("cedar")

        XCTAssertEqual(harness.controller.changeVoiceCalls, ["cedar"])
        XCTAssertTrue(harness.controller.setParameterCalls.isEmpty)
        XCTAssertEqual(harness.viewModel.voice, "cedar")
        await harness.viewModel.dispose()
    }

    func testAnotherFeatureHoldingTheMicBlocksStart() async {
        let harness = makeHarness()
        let lease = harness.controller.sessionGuard.acquire(
            .transcription,
        )
        XCTAssertNotNil(lease)
        XCTAssertFalse(harness.viewModel.canStart)

        harness.controller.sessionGuard.release(lease!)
        XCTAssertTrue(harness.viewModel.canStart)
        await harness.viewModel.dispose()
    }

    func testDisposeReleasesTheSessionAndStopsListening() async {
        let controller = FakeConversationSessionController()
        let viewModel = SpeechToSpeechViewModel(
            sessionService: controller,
        )
        await viewModel.dispose()

        controller.publish(
            ConversationSessionSnapshot(muted: true),
        )
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(controller.disposeCalls, 1)
        XCTAssertFalse(viewModel.state.muted)
    }

    private func makeHarness() -> (
        controller: FakeConversationSessionController,
        viewModel: SpeechToSpeechViewModel,
    ) {
        let controller = FakeConversationSessionController()
        let viewModel = SpeechToSpeechViewModel(
            sessionService: controller,
        )
        return (controller, viewModel)
    }

    private func waitFor(
        _ viewModel: SpeechToSpeechViewModel,
        _ condition: (SpeechToSpeechState) -> Bool,
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
