/// The wait between the tap and the first audible word.
enum ConversationConnectProgress {
    static func caption(
        for state: RealtimeSessionState,
    ) -> String? {
        switch state {
        case .requestingPermission:
            ConversationCopy.connectingPermission
        case .preparingAudio:
            ConversationCopy.connecting
        case .creatingTask:
            ConversationCopy.startingTask
        case .connectingSocket:
            ConversationCopy.connecting
        case .waitingForStream:
            ConversationCopy.connectingStream
        default:
            nil
        }
    }
}
