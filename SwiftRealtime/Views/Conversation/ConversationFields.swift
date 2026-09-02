enum ConversationFields {
    static let voiceId = WiroModelCatalog.voiceFieldId
    static let instructionsId = WiroModelCatalog.instructionsFieldId

    static func voice(
        in model: ModelDefinition,
    ) -> ModelFieldDefinition? {
        model.firstPassFields.first { $0.id == voiceId }
    }

    static func settingsFields(
        in model: ModelDefinition,
    ) -> [ModelFieldDefinition] {
        model.firstPassFields.filter { field in
            field.id != voiceId && field.id != instructionsId
        }
    }

    static func displayName(_ value: String) -> String {
        guard let first = value.first else {
            return value
        }
        return String(first).uppercased() + value.dropFirst()
    }
}
