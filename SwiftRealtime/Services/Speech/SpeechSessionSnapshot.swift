import Foundation

/// Everything a text-to-speech session knows at one moment.
///
/// Visual state is excluded. Tests read the session through this alone.
struct SpeechSessionSnapshot: Equatable, Sendable {
    var selectedModel: ModelDefinition
    var sessionState: RealtimeSessionState
    var elapsed: Duration
    var isPlaying: Bool
    var errorMessage: String?

    init(
        selectedModel: ModelDefinition,
        sessionState: RealtimeSessionState = .idle,
        elapsed: Duration = .zero,
        isPlaying: Bool = false,
        errorMessage: String? = nil,
    ) {
        self.selectedModel = selectedModel
        self.sessionState = sessionState
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.errorMessage = errorMessage
    }

    func copyWith(
        selectedModel: ModelDefinition? = nil,
        sessionState: RealtimeSessionState? = nil,
        elapsed: Duration? = nil,
        isPlaying: Bool? = nil,
        errorMessage: String?? = nil,
    ) -> SpeechSessionSnapshot {
        SpeechSessionSnapshot(
            selectedModel: selectedModel ?? self.selectedModel,
            sessionState: sessionState ?? self.sessionState,
            elapsed: elapsed ?? self.elapsed,
            isPlaying: isPlaying ?? self.isPlaying,
            errorMessage: errorMessage ?? self.errorMessage,
        )
    }
}
