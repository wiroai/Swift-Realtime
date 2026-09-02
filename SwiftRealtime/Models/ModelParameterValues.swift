import Foundation

enum ModelRequestValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)

    var jsonObject: Any {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        }
    }
}

extension Dictionary where Key == String, Value == ModelRequestValue {
    var jsonObject: [String: Any] {
        mapValues(\.jsonObject)
    }
}

/// Catalog defaults plus the ids an application chooses to replace.
///
/// Overrides replace the catalog defaults for the ids they name. Ids
/// the model does not expose are ignored.
struct ModelParameterValues: Equatable, Sendable {
    private let definitions: [String: ModelFieldDefinition]
    private var values: [String: String]

    init(
        fields: [ModelFieldDefinition],
        overrides: [String: String] = [:],
    ) {
        var definitions: [String: ModelFieldDefinition] = [:]
        var values: [String: String] = [:]
        for field in fields where field.includeInFirstPass {
            definitions[field.id] = field
            values[field.id] = overrides[field.id]
                ?? field.defaultValue
                ?? ""
        }
        self.definitions = definitions
        self.values = values
    }

    func value(for id: String) -> String? {
        values[id]
    }

    mutating func setValue(_ value: String, for id: String) {
        guard values[id] != nil else {
            return
        }
        values[id] = value
    }

    func snapshot() -> [String: String] {
        var snapshot: [String: String] = [:]
        for (id, value) in values {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines,
            )
            if !trimmed.isEmpty {
                snapshot[id] = value
            }
        }
        return snapshot
    }

    func requestSnapshot() -> [String: ModelRequestValue] {
        var snapshot: [String: ModelRequestValue] = [:]
        for (id, value) in self.snapshot() {
            guard let definition = definitions[id] else {
                continue
            }
            snapshot[id] = requestValue(
                definition: definition,
                value: value,
            )
        }
        return snapshot
    }

    private func requestValue(
        definition: ModelFieldDefinition,
        value: String,
    ) -> ModelRequestValue {
        switch definition.kind {
        case .number:
            if let parsed = Int(value) {
                return .int(parsed)
            }
            return .string(value)
        case .float:
            if let parsed = Double(value) {
                return .double(parsed)
            }
            return .string(value)
        case .text, .textarea, .select:
            return .string(value)
        }
    }
}
