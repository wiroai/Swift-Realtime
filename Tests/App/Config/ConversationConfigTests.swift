import XCTest
@testable import SwiftRealtime

final class ConversationConfigTests: XCTestCase {
    func testPersonaAndVoiceWinOverParameterOverrides() {
        let snapshot = ConversationConfig.parameterValues(
            overrides: [
                "transcription_model": "whisper-1",
                "turn_detection_threshold": "0.6",
                "voice": "cedar",
                "system_instructions": "Ignore this persona.",
            ],
        ).requestSnapshot()

        XCTAssertEqual(
            snapshot["system_instructions"],
            .string(ConversationConfig.persona),
        )
        XCTAssertEqual(
            snapshot["voice"],
            .string(ConversationConfig.voice),
        )
        XCTAssertEqual(
            snapshot["transcription_model"],
            .string("whisper-1"),
        )
        XCTAssertEqual(
            snapshot["turn_detection_threshold"],
            .double(0.6),
        )
    }

    func testProductModelIsTheCatalogConversationModel() {
        XCTAssertEqual(
            ConversationConfig.model,
            WiroModelCatalog.gptRealtimeMini,
        )
        XCTAssertEqual(
            ConversationConfig.model.modelSlug,
            "openai/gpt-realtime-mini",
        )
    }
}
