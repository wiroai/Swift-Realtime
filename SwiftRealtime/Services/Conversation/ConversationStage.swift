/// What the conversation looks like to the person using it.
///
/// `RealtimeSessionState` describes the transport; this describes the
/// screen. The five states between idle and streaming collapse into
/// `connecting`.
enum ConversationStage: Sendable, Equatable, Hashable {
    case ready
    case connecting
    case live
    case ending
    case failed

    /// True while the session is mid-transition and the primary action
    /// should not be offered again.
    var isTransitional: Bool {
        self == .connecting || self == .ending
    }
}

extension RealtimeSessionState {
    var conversationStage: ConversationStage {
        switch self {
        case .idle:
            .ready
        case .requestingPermission, .preparingAudio, .creatingTask,
             .connectingSocket, .waitingForStream:
            .connecting
        case .streaming:
            .live
        case .stopping:
            .ending
        case .completed:
            .ready
        case .failure:
            .failed
        }
    }
}
