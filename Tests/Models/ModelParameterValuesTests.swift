import XCTest
@testable import SwiftRealtime

final class ModelParameterValuesTests: XCTestCase {
    func testConvertsNumericModelFieldsForJSONRequests() {
        let parameters = ModelParameterValues(
            fields: WiroModelCatalog.voxcpm2.firstPassFields,
        )
        let snapshot = parameters.requestSnapshot()

        XCTAssertEqual(snapshot["cfgValue"], .double(2.0))
        XCTAssertEqual(snapshot["inferenceSteps"], .int(10))
    }

    func testUsesNoiseResistantConversationDefaults() {
        let parameters = ModelParameterValues(
            fields: WiroModelCatalog.gptRealtimeMini.firstPassFields,
        )
        let snapshot = parameters.requestSnapshot()

        XCTAssertEqual(
            snapshot["turn_detection_threshold"],
            .double(0.75),
        )
        XCTAssertEqual(
            snapshot["turn_detection_silence_ms"],
            .int(700),
        )
    }

    func testOverridesReplaceCatalogDefaultsAndIgnoreUnknownIDs() {
        let parameters = ModelParameterValues(
            fields: WiroModelCatalog.gptRealtimeMini.firstPassFields,
            overrides: [
                "voice": "cedar",
                "system_instructions": "You answer support questions.",
                "not_a_field": "ignored",
            ],
        )
        let snapshot = parameters.requestSnapshot()

        XCTAssertEqual(snapshot["voice"], .string("cedar"))
        XCTAssertEqual(
            snapshot["system_instructions"],
            .string("You answer support questions."),
        )
        XCTAssertNil(snapshot["not_a_field"])
        XCTAssertEqual(
            snapshot["turn_detection_threshold"],
            .double(0.75),
        )
    }
}
