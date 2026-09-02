import XCTest
@testable import SwiftRealtime

final class SpeechScreenHelpersTests: XCTestCase {
    func testConnectCaptionsNameTheWaitThePersonIsIn() {
        XCTAssertEqual(
            SpeechConnectProgress.caption(
                for: .creatingTask,
                isPlaying: false,
            ),
            SpeechCopy.startingTask,
        )
        XCTAssertEqual(
            SpeechConnectProgress.caption(
                for: .streaming,
                isPlaying: false,
            ),
            SpeechCopy.buffering,
        )
        XCTAssertEqual(
            SpeechConnectProgress.caption(
                for: .streaming,
                isPlaying: true,
            ),
            SpeechCopy.speaking,
        )
        XCTAssertEqual(
            SpeechConnectProgress.caption(
                for: .stopping,
                isPlaying: false,
            ),
            SpeechCopy.finishing,
        )
        XCTAssertNil(
            SpeechConnectProgress.caption(
                for: .idle,
                isPlaying: false,
            ),
        )
    }

    func testConnectingIsOnlyTheWaitBetweenTapAndStream() {
        var state = TextToSpeechState(
            selectedModel: WiroModelCatalog.mossTtsRealtime,
            sessionState: .creatingTask,
        )
        XCTAssertTrue(state.showsConnecting)
        XCTAssertFalse(state.isLive)
        XCTAssertFalse(state.canEditPrompt)

        state.sessionState = .streaming
        XCTAssertFalse(state.showsConnecting)
        XCTAssertTrue(state.isLive)

        state.sessionState = .stopping
        XCTAssertTrue(state.isEnding)
        XCTAssertFalse(state.showsConnecting)
    }

    func testSettingsLeaveOutThePromptField() {
        XCTAssertEqual(
            SpeechFields.settingsFields(
                in: WiroModelCatalog.mossTtsRealtime,
            ).count,
            0,
        )
        XCTAssertEqual(
            SpeechFields.settingsFields(
                in: WiroModelCatalog.voxcpm2,
            ).map(\.id),
            ["cfgValue", "inferenceSteps"],
        )
    }

    func testCharacterCountIsCopyNotARawNumber() {
        XCTAssertEqual(SpeechCopy.characterCount(12), "12 characters")
    }
}
