import XCTest
@testable import SwiftRealtime

final class SpeechScreenHelpersTests: XCTestCase {
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
