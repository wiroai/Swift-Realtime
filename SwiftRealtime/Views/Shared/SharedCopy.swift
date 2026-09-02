/// Wording every screen shares.
enum SharedCopy {
    static let done = "Done"
    static let ok = "OK"
    static let listening = "Listening"
    static let muted = "Muted"
}

/// Catalog option values are lowercase ids (`cedar`, `balanced`).
/// The toolbar shows them as names.
enum OptionTitle {
    static func capitalized(_ value: String) -> String {
        guard let first = value.first else {
            return value
        }
        return String(first).uppercased() + value.dropFirst()
    }
}
