import XCTest
@testable import SwiftRealtime

final class ConversationScreenHelpersTests: XCTestCase {
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

    func testRestoringIsLiveWithoutAudioFlowing() {
        var state = SpeechToSpeechState(sessionState: .streaming)
        XCTAssertFalse(state.isRestoring)

        state.sessionState = .creatingTask
        XCTAssertTrue(state.isRestoring)
        XCTAssertFalse(state.showsConnecting)

        state.reportsConnecting = true
        XCTAssertFalse(state.isRestoring)
        XCTAssertTrue(state.showsConnecting)

        state.reportsConnecting = false
        state.sessionState = .stopping
        XCTAssertFalse(state.isRestoring)
    }
}
