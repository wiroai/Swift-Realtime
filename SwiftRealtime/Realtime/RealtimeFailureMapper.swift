/// Translates session errors into a user-facing message and a stable
/// machine-readable code.
///
/// Errors outside the project's failure types collapse to
/// `fallbackMessage` and the `unknown` code, so raw exception text never
/// reaches the UI or the protocol log.
struct RealtimeFailureMapper: Sendable {
    static let unknownCode = "unknown"

    let fallbackMessage: String

    func message(for error: Error) -> String {
        if let failure = error as? WiroFailure {
            return failure.message
        }
        if let failure = error as? AudioFailure {
            return failure.message
        }
        return fallbackMessage
    }

    func code(for error: Error) -> String {
        if let failure = error as? WiroFailure {
            return String(describing: failure.code)
        }
        if let failure = error as? AudioFailure {
            return String(describing: failure.code)
        }
        return Self.unknownCode
    }
}
