enum RealtimeDirection: Sendable, Equatable, Hashable {
    case speechToSpeech
    case speechToText
    case textToSpeech
}

enum ModelFieldKind: Sendable, Equatable, Hashable {
    case text
    case textarea
    case select
    case number
    case float
}

struct ModelFieldOption: Sendable, Equatable, Hashable {
    let value: String
}

struct ModelFieldDefinition: Sendable, Equatable, Hashable {
    let id: String
    let label: String
    let kind: ModelFieldKind
    let isRequired: Bool
    let includeInFirstPass: Bool
    let options: [ModelFieldOption]
    let defaultValue: String?

    init(
        id: String,
        label: String,
        kind: ModelFieldKind,
        isRequired: Bool,
        includeInFirstPass: Bool,
        options: [ModelFieldOption] = [],
        defaultValue: String? = nil,
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.isRequired = isRequired
        self.includeInFirstPass = includeInFirstPass
        self.options = options
        self.defaultValue = defaultValue
    }
}

struct ModelDefinition: Sendable, Equatable, Hashable {
    let owner: String
    let slug: String
    let displayName: String
    let direction: RealtimeDirection
    let fields: [ModelFieldDefinition]
    /// The free-text field a text-to-speech model speaks, when it has
    /// one. Models name it differently, so the schema says which.
    let promptFieldId: String?

    init(
        owner: String,
        slug: String,
        displayName: String,
        direction: RealtimeDirection,
        fields: [ModelFieldDefinition],
        promptFieldId: String? = nil,
    ) {
        self.owner = owner
        self.slug = slug
        self.displayName = displayName
        self.direction = direction
        self.fields = fields
        self.promptFieldId = promptFieldId
    }

    var modelSlug: String {
        "\(owner)/\(slug)"
    }

    var firstPassFields: [ModelFieldDefinition] {
        fields.filter(\.includeInFirstPass)
    }
}
