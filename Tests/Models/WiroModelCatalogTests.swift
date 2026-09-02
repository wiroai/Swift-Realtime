import XCTest
@testable import SwiftRealtime

final class WiroModelCatalogTests: XCTestCase {
    func testCatalogFieldIDsMatchThe20260821MCPSchemas() {
        XCTAssertEqual(
            WiroModelCatalog.gptRealtimeMini.modelSlug,
            "openai/gpt-realtime-mini",
        )
        XCTAssertEqual(
            WiroModelCatalog.gptRealtimeMini.firstPassFields.map(\.id),
            [
                "voice",
                "system_instructions",
                "transcription_model",
                "input_audio_format",
                "output_audio_format",
                "input_audio_rate",
                "output_audio_rate",
                "turn_detection_threshold",
                "turn_detection_silence_ms",
            ],
        )

        let voxtralFields =
            WiroModelCatalog.voxtralMiniRealtime.firstPassFields
        XCTAssertEqual(voxtralFields.count, 1)
        XCTAssertEqual(voxtralFields[0].id, "transcriptionDelay")
        XCTAssertEqual(voxtralFields[0].defaultValue, "balanced")

        XCTAssertEqual(
            WiroModelCatalog.mossTtsRealtime.firstPassFields.map(\.id),
            ["text"],
        )
        XCTAssertEqual(
            WiroModelCatalog.voxcpm2.firstPassFields.map(\.id),
            ["prompt", "cfgValue", "inferenceSteps"],
        )
        XCTAssertEqual(
            WiroModelCatalog.voxcpm2.fields
                .first { $0.id == "cfgValue" }?
                .defaultValue,
            "2.0",
        )
    }
}
