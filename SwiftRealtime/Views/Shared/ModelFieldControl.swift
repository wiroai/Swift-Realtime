/// Native Form control a catalog field draws as.
///
/// Features do not pick Picker / TextField / Toggle themselves. The
/// field kind (and, for a two-option boolean select, the option values)
/// decides. Custom chrome is not part of this mapping.
enum ModelFieldControl: Equatable, Sendable {
    case picker
    case textField(ModelFieldTextSpec)
    case toggle(on: String, off: String)
}

struct ModelFieldTextSpec: Equatable, Sendable {
    var isMultiline: Bool
    var keyboard: ModelFieldKeyboard
}

enum ModelFieldKeyboard: Equatable, Sendable {
    case `default`
    case number
    case decimal
}

extension ModelFieldDefinition {
    /// Control the settings Form uses for this catalog field.
    var control: ModelFieldControl {
        switch kind {
        case .select:
            if let pair = ModelFieldControl.booleanPair(in: options) {
                return .toggle(on: pair.on, off: pair.off)
            }
            if !options.isEmpty {
                return .picker
            }
            return .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .default,
                ),
            )
        case .textarea:
            return .textField(
                ModelFieldTextSpec(
                    isMultiline: true,
                    keyboard: .default,
                ),
            )
        case .number:
            return .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .number,
                ),
            )
        case .float:
            return .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .decimal,
                ),
            )
        case .text:
            return .textField(
                ModelFieldTextSpec(
                    isMultiline: false,
                    keyboard: .default,
                ),
            )
        }
    }
}

extension ModelFieldControl {
    /// Two-option selects whose values are a known boolean pair become
    /// a Toggle. Rates, models, and other pairs stay a Picker.
    static func booleanPair(
        in options: [ModelFieldOption],
    ) -> (on: String, off: String)? {
        guard options.count == 2 else {
            return nil
        }
        let values = options.map(\.value)
        let lowered = values.map { $0.lowercased() }
        let pairs = [
            ("true", "false"),
            ("yes", "no"),
            ("on", "off"),
            ("1", "0"),
        ]
        for (on, off) in pairs {
            guard let onIndex = lowered.firstIndex(of: on),
                  let offIndex = lowered.firstIndex(of: off)
            else {
                continue
            }
            return (on: values[onIndex], off: values[offIndex])
        }
        return nil
    }
}
