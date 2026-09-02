import Foundation

/// Everything a conversation session knows about itself at one moment.
///
/// The service's whole output surface. Transcripts and the clock live
/// here because a reconnect preserves what was said and the limit
/// watches the clock. Tests read the session through this alone.
struct ConversationSessionSnapshot: Equatable, Sendable {
    var sessionState: RealtimeSessionState
    var elapsed: Duration
    var userTranscript: String
    var aiTranscript: String
    var microphoneActive: Bool
    var muted: Bool
    var isReconfiguring: Bool
    var isSuspended: Bool
    var errorMessage: String?
    var canOpenSystemSettings: Bool

    init(
        sessionState: RealtimeSessionState = .idle,
        elapsed: Duration = .zero,
        userTranscript: String = "",
        aiTranscript: String = "",
        microphoneActive: Bool = false,
        muted: Bool = false,
        isReconfiguring: Bool = false,
        isSuspended: Bool = false,
        errorMessage: String? = nil,
        canOpenSystemSettings: Bool = false,
    ) {
        self.sessionState = sessionState
        self.elapsed = elapsed
        self.userTranscript = userTranscript
        self.aiTranscript = aiTranscript
        self.microphoneActive = microphoneActive
        self.muted = muted
        self.isReconfiguring = isReconfiguring
        self.isSuspended = isSuspended
        self.errorMessage = errorMessage
        self.canOpenSystemSettings = canOpenSystemSettings
    }

    var stage: ConversationStage {
        sessionState.conversationStage
    }

    func copyWith(
        sessionState: RealtimeSessionState? = nil,
        elapsed: Duration? = nil,
        userTranscript: String? = nil,
        aiTranscript: String? = nil,
        microphoneActive: Bool? = nil,
        muted: Bool? = nil,
        isReconfiguring: Bool? = nil,
        isSuspended: Bool? = nil,
        errorMessage: String?? = nil,
        canOpenSystemSettings: Bool? = nil,
    ) -> ConversationSessionSnapshot {
        ConversationSessionSnapshot(
            sessionState: sessionState ?? self.sessionState,
            elapsed: elapsed ?? self.elapsed,
            userTranscript: userTranscript ?? self.userTranscript,
            aiTranscript: aiTranscript ?? self.aiTranscript,
            microphoneActive: microphoneActive
                ?? self.microphoneActive,
            muted: muted ?? self.muted,
            isReconfiguring: isReconfiguring ?? self.isReconfiguring,
            isSuspended: isSuspended ?? self.isSuspended,
            errorMessage: errorMessage ?? self.errorMessage,
            canOpenSystemSettings: canOpenSystemSettings
                ?? self.canOpenSystemSettings,
        )
    }
}
