import XCTest
@testable import SwiftRealtime

final class ModelFieldControlTests: XCTestCase {
    func testSelectWithOptionsIsAPicker() {
        XCTAssertEqual(
            field(kind: .select, options: "marin", "cedar").control,
            .picker,
        )
    }

    func testEmptySelectFallsBackToATextField() {
        XCTAssertEqual(
            field(kind: .select).control,
            .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .default,
                ),
            ),
        )
    }

    func testTextareaIsAMultilineTextField() {
        XCTAssertEqual(
            field(kind: .textarea).control,
            .textField(
                ModelFieldTextSpec(
                    isMultiline: true,
                    keyboard: .default,
                ),
            ),
        )
    }

    func testNumberAndFloatUseNumericKeyboards() {
        XCTAssertEqual(
            field(kind: .number).control,
            .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .number,
                ),
            ),
        )
        XCTAssertEqual(
            field(kind: .float).control,
            .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .decimal,
                ),
            ),
        )
    }

    func testPlainTextIsASingleLineField() {
        XCTAssertEqual(
            field(kind: .text).control,
            .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .default,
                ),
            ),
        )
    }

    func testBooleanSelectPairsBecomeAToggle() {
        XCTAssertEqual(
            field(kind: .select, options: "true", "false").control,
            .toggle(on: "true", off: "false"),
        )
        XCTAssertEqual(
            field(kind: .select, options: "off", "ON").control,
            .toggle(on: "ON", off: "off"),
        )
        XCTAssertEqual(
            field(kind: .select, options: "1", "0").control,
            .toggle(on: "1", off: "0"),
        )
        XCTAssertEqual(
            field(kind: .select, options: "yes", "no").control,
            .toggle(on: "yes", off: "no"),
        )
    }

    func testTwoOptionRatesStayAPicker() {
        XCTAssertEqual(
            field(kind: .select, options: "24000", "8000").control,
            .picker,
        )
    }

    func testConversationSettingsMapToPickerAndNumericFields() {
        let fields = ConversationFields.settingsFields(
            in: WiroModelCatalog.gptRealtimeMini,
        )
        XCTAssertEqual(fields.map(\.id), [
            "transcription_model",
            "input_audio_format",
            "output_audio_format",
            "input_audio_rate",
            "output_audio_rate",
            "turn_detection_threshold",
            "turn_detection_silence_ms",
        ])
        XCTAssertEqual(
            fields.map(\.control),
            [
                .picker,
                .picker,
                .picker,
                .picker,
                .picker,
                .textField(
                    ModelFieldTextSpec(
                        isMultiline: false,
                        keyboard: .decimal,
                    ),
                ),
                .textField(
                    ModelFieldTextSpec(
                        isMultiline: false,
                        keyboard: .number,
                    ),
                ),
            ],
        )
    }

    func testSpeechSettingsUseNumericFields() {
        let fields = SpeechFields.settingsFields(
            in: WiroModelCatalog.voxcpm2,
        )
        XCTAssertEqual(fields.map(\.id), [
            "cfgValue",
            "inferenceSteps",
        ])
        XCTAssertEqual(
            fields.map(\.control),
            [
                .textField(
                    ModelFieldTextSpec(
                        isMultiline: false,
                        keyboard: .decimal,
                    ),
                ),
                .textField(
                    ModelFieldTextSpec(
                        isMultiline: false,
                        keyboard: .number,
                    ),
                ),
            ],
        )
    }

    private func field(
        kind: ModelFieldKind,
        options: String...,
    ) -> ModelFieldDefinition {
        ModelFieldDefinition(
            id: "field",
            label: "Field",
            kind: kind,
            isRequired: false,
            includeInFirstPass: true,
            options: options.map { ModelFieldOption(value: $0) },
        )
    }
}
