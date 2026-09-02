enum RealtimeSessionState: Sendable, Equatable, Hashable {
    case idle
    case requestingPermission
    case preparingAudio
    case creatingTask
    case connectingSocket
    case waitingForStream
    case streaming
    case stopping
    case completed
    case failure

    var isIdleLike: Bool {
        self == .idle || self == .completed || self == .failure
    }

    var isActive: Bool { !isIdleLike }

    var canStart: Bool { isIdleLike }

    var canStop: Bool { isActive }
}
