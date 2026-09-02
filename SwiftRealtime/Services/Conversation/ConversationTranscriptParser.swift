enum ConversationTranscript: Equatable, Sendable {
    case user(String)
    case ai(String)

    var text: String {
        switch self {
        case let .user(text), let .ai(text):
            text
        }
    }
}

/// Recognises the speaker prefixes the conversation model puts on its
/// transcript output. Both speakers share one output channel.
struct ConversationTranscriptParser: Sendable {
    static let userPrefix = "TRANSCRIPT_USER:"
    static let aiPrefix = "TRANSCRIPT_AI:"

    func parse(_ message: String) -> ConversationTranscript? {
        if message.hasPrefix(Self.userPrefix) {
            let text = String(
                message.dropFirst(Self.userPrefix.count),
            )
            return .user(text)
        }
        if message.hasPrefix(Self.aiPrefix) {
            let text = String(
                message.dropFirst(Self.aiPrefix.count),
            )
            return .ai(text)
        }
        return nil
    }
}
