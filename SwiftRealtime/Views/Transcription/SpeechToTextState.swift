import Foundation

/// What the transcription screen actually draws.
///
/// The session's snapshot knows more; a field earns its place here by
/// having a control that rebuilds on it. The model is not a field at
/// all, because this screen runs against one fixed model.
struct SpeechToTextState: Equatable, Sendable {
    var sessionState: RealtimeSessionState = .idle
    var elapsed: Duration = .zero
    var transcript: String = ""
    var muted = false
    var errorMessage: String?
    var canOpenSystemSettings = false
    var showsSystemSettingsAlert = false

    var showsConnecting: Bool {
        switch sessionState {
        case .requestingPermission, .preparingAudio, .creatingTask,
             .connectingSocket, .waitingForStream:
            true
        default:
            false
        }
    }

    var isLive: Bool { sessionState == .streaming }

    var isEnding: Bool { sessionState == .stopping }

    var canClearTranscript: Bool {
        sessionState.isIdleLike && !transcript.isEmpty
    }
}
