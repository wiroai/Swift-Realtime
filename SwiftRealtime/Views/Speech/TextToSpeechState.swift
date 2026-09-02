import Foundation

/// What the speech screen actually draws.
///
/// The session's snapshot knows more; a field earns its place here
/// by having a control that rebuilds on it. The model stays because
/// this screen lets the user change it.
struct TextToSpeechState: Equatable, Sendable {
    var selectedModel: ModelDefinition
    var sessionState: RealtimeSessionState = .idle
    var elapsed: Duration = .zero
    var isPlaying = false
    var errorMessage: String?

    var showsConnecting: Bool {
        switch sessionState {
        case .preparingAudio, .creatingTask, .connectingSocket,
             .waitingForStream:
            true
        default:
            false
        }
    }

    var isLive: Bool { sessionState == .streaming }

    var isEnding: Bool { sessionState == .stopping }

    var canEditPrompt: Bool { !sessionState.isActive }
}
