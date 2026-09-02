import XCTest
@testable import SwiftRealtime

final class ConversationScreenHelpersTests: XCTestCase {
    func testConnectCaptionsNameTheWaitThePersonIsIn() {
        XCTAssertEqual(
            ConversationConnectProgress.caption(
                for: .requestingPermission,
            ),
            ConversationCopy.connectingPermission,
        )
        XCTAssertEqual(
            ConversationConnectProgress.caption(
                for: .waitingForStream,
            ),
            ConversationCopy.connectingStream,
        )
        XCTAssertEqual(
            ConversationConnectProgress.caption(
                for: .creatingTask,
            ),
            ConversationCopy.startingTask,
        )
        XCTAssertNil(
            ConversationConnectProgress.caption(for: .streaming),
        )
        XCTAssertNil(
            ConversationConnectProgress.caption(for: .idle),
        )
    }

    func testSettingsFieldsHideVoiceAndPersona() {
        let fields = ConversationFields.settingsFields(
            in: WiroModelCatalog.gptRealtimeMini,
        )
        XCTAssertFalse(
            fields.contains { $0.id == ConversationFields.voiceId },
        )
        XCTAssertFalse(
            fields.contains {
                $0.id == ConversationFields.instructionsId
            },
        )
        XCTAssertTrue(
            fields.contains { $0.id == "transcription_model" },
        )
    }

    func testDisplayedStageHidesAnUnaskedConnect() {
        var state = SpeechToSpeechState(
            sessionState: .connectingSocket,
        )
        XCTAssertEqual(state.displayedStage, .live)
        XCTAssertFalse(state.showsConnecting)

        state.reportsConnecting = true
        XCTAssertEqual(state.displayedStage, .connecting)
        XCTAssertTrue(state.showsConnecting)
    }

    func testDisplayNameCapitalizesTheFirstLetter() {
        XCTAssertEqual(
            ConversationFields.displayName("cedar"),
            "Cedar",
        )
        XCTAssertEqual(ConversationFields.displayName(""), "")
    }
}
