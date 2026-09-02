/// Every string the speech screen shows.
enum SpeechCopy {
    static let title = "Speech"
    static let promptPlaceholder = "Text to speak"
    static let model = "Model"
    static let play = "Play"
    static let stop = "Stop"
    static let cancel = "Cancel"
    static let settings = "Settings"

    static func characterCount(_ count: Int) -> String {
        "\(count) characters"
    }
}

enum SpeechFields {
    static let models: [ModelDefinition] = [
        WiroModelCatalog.mossTtsRealtime,
        WiroModelCatalog.voxcpm2,
    ]

    static func settingsFields(
        in model: ModelDefinition,
    ) -> [ModelFieldDefinition] {
        model.firstPassFields.filter { $0.id != model.promptFieldId }
    }
}
