import SwiftUI

/// One catalog field as a Form row: Picker, TextField, or Toggle.
///
/// The row is the system control. It does not wrap Form, NavigationStack,
/// or the settings sheet — those stay with the feature.
struct ModelParameterField: View {
    let field: ModelFieldDefinition
    @Binding var text: String
    var optionTitle: (String) -> String = { $0 }

    var body: some View {
        Group {
            switch field.control {
            case .picker:
                picker
            case let .textField(spec):
                textField(spec)
            case let .toggle(on, off):
                toggle(on: on, off: off)
            }
        }
        .accessibilityIdentifier("field-\(field.id)")
    }

    private var picker: some View {
        Picker(field.label, selection: pickerSelection) {
            ForEach(field.options, id: \.value) { option in
                Text(optionTitle(option.value))
                    .tag(option.value)
            }
        }
    }

    private func textField(
        _ spec: ModelFieldTextSpec,
    ) -> some View {
        TextField(
            field.label,
            text: $text,
            axis: spec.isMultiline ? .vertical : .horizontal,
        )
        .lineLimit(spec.isMultiline ? 4 : 1)
        .keyboardType(keyboardType(spec.keyboard))
    }

    private func toggle(on: String, off: String) -> some View {
        Toggle(
            field.label,
            isOn: Binding(
                get: { text == on },
                set: { text = $0 ? on : off },
            ),
        )
    }

    /// Picker needs a value in `options`. An unknown snapshot falls
    /// back to the first option without writing it back.
    private var pickerSelection: Binding<String> {
        Binding(
            get: {
                if field.options.contains(where: { $0.value == text }) {
                    return text
                }
                return field.options.first?.value ?? text
            },
            set: { text = $0 },
        )
    }

    private func keyboardType(
        _ keyboard: ModelFieldKeyboard,
    ) -> UIKeyboardType {
        switch keyboard {
        case .default:
            .default
        case .number:
            .numberPad
        case .decimal:
            .decimalPad
        }
    }
}

/// Catalog fields as Form rows. The feature still owns the `Form`.
struct ModelParameterForm: View {
    let fields: [ModelFieldDefinition]
    let value: (String) -> String
    let setValue: (String, String) -> Void
    var optionTitle: (String) -> String = { $0 }

    var body: some View {
        ForEach(fields, id: \.id) { field in
            ModelParameterField(
                field: field,
                text: Binding(
                    get: { value(field.id) },
                    set: { setValue($0, field.id) },
                ),
                optionTitle: optionTitle,
            )
        }
    }
}
