enum RealtimeAudioProfile: Sendable {
    case conversation
    case transcription
    case speech

    var requiresMicrophone: Bool {
        switch self {
        case .conversation, .transcription:
            true
        case .speech:
            false
        }
    }
}

enum AudioPreparationResult: Sendable, Equatable {
    case ready
    case permissionDenied
    case permissionPermanentlyDenied
    case permissionRestricted
    case activationDenied
    case unavailable

    /// True when tapping again can never help and only system
    /// settings can, which is the one failure the app must offer
    /// a way out of.
    var needsSystemSettings: Bool {
        self == .permissionPermanentlyDenied
    }

    var errorMessage: String? {
        switch self {
        case .ready:
            nil
        case .permissionDenied:
            "Microphone permission was denied. "
                + "Allow access and try again."
        case .permissionPermanentlyDenied:
            "Microphone access is disabled. "
                + "Enable it in system settings."
        case .permissionRestricted:
            "Microphone access is restricted on this device."
        case .activationDenied:
            "The audio session could not be activated. Try again."
        case .unavailable:
            "The audio session could not be prepared. Try again."
        }
    }
}

enum RealtimeAudioInterruption: Sendable, Equatable {
    case began
    case ended
}

protocol RealtimeAudioSession: AnyObject, Sendable {
    var interruptions: AsyncStream<RealtimeAudioInterruption> { get }
    var becomingNoisy: AsyncStream<Void> { get }
    var routeChanges: AsyncStream<Void> { get }

    func prepare(
        _ profile: RealtimeAudioProfile,
    ) async -> AudioPreparationResult
    func deactivate() async
    func openSystemSettings() async -> Bool
    func dispose() async
}
