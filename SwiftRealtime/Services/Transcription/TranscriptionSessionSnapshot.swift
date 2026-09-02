import Foundation

/// Everything a transcription session knows about itself at one moment.
///
/// Visual state is excluded. Tests read the session through this alone.
struct TranscriptionSessionSnapshot: Equatable, Sendable {
    var sessionState: RealtimeSessionState
    var elapsed: Duration
    var transcript: String
    var microphoneActive: Bool
    var muted: Bool
    var errorMessage: String?
    var canOpenSystemSettings: Bool

    init(
        sessionState: RealtimeSessionState = .idle,
        elapsed: Duration = .zero,
        transcript: String = "",
        microphoneActive: Bool = false,
        muted: Bool = false,
        errorMessage: String? = nil,
        canOpenSystemSettings: Bool = false,
    ) {
        self.sessionState = sessionState
        self.elapsed = elapsed
        self.transcript = transcript
        self.microphoneActive = microphoneActive
        self.muted = muted
        self.errorMessage = errorMessage
        self.canOpenSystemSettings = canOpenSystemSettings
    }

    func copyWith(
        sessionState: RealtimeSessionState? = nil,
        elapsed: Duration? = nil,
        transcript: String? = nil,
        microphoneActive: Bool? = nil,
        muted: Bool? = nil,
        errorMessage: String?? = nil,
        canOpenSystemSettings: Bool? = nil,
    ) -> TranscriptionSessionSnapshot {
        TranscriptionSessionSnapshot(
            sessionState: sessionState ?? self.sessionState,
            elapsed: elapsed ?? self.elapsed,
            transcript: transcript ?? self.transcript,
            microphoneActive: microphoneActive
                ?? self.microphoneActive,
            muted: muted ?? self.muted,
            errorMessage: errorMessage ?? self.errorMessage,
            canOpenSystemSettings: canOpenSystemSettings
                ?? self.canOpenSystemSettings,
        )
    }
}
