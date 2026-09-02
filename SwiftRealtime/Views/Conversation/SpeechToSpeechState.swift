import Foundation

/// What the conversation screen actually draws.
struct SpeechToSpeechState: Equatable, Sendable {
    var sessionState: RealtimeSessionState = .idle
    var elapsed: Duration = .zero
    var userTranscript: String = ""
    var aiTranscript: String = ""
    var muted = false
    var isReconfiguring = false
    var reportsConnecting = false
    var errorMessage: String?
    var canOpenSystemSettings = false
    var showsSystemSettingsAlert = false

    /// Whether someone tapped Start and is still waiting to be heard.
    ///
    /// Raised by the view model's own `start`, never by a session
    /// state. A dropped socket or voice change must not look like a
    /// fresh connect.
    var displayedStage: ConversationStage {
        let stage = sessionState.conversationStage
        if !reportsConnecting, stage == .connecting {
            return .live
        }
        return stage
    }

    var showsConnecting: Bool {
        reportsConnecting && sessionState.conversationStage == .connecting
    }
}
