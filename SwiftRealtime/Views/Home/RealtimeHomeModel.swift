import Foundation
import Observation

enum RealtimeDestination: String, CaseIterable, Hashable, Identifiable {
    case conversation
    case transcription
    case speech

    var id: Self { self }

    var title: String {
        switch self {
        case .conversation:
            "Conversation"
        case .transcription:
            "Transcription"
        case .speech:
            "Speech"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation:
            "bubble.left.and.bubble.right"
        case .transcription:
            "mic"
        case .speech:
            "waveform"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .conversation:
            "bubble.left.and.bubble.right.fill"
        case .transcription:
            "mic.fill"
        case .speech:
            "waveform"
        }
    }

    var sessionOwner: RealtimeSessionOwner {
        switch self {
        case .conversation:
            .conversation
        case .transcription:
            .transcription
        case .speech:
            .speech
        }
    }
}

/// Owns the tab selection and the audio/session objects every
/// destination shares. Features never create a second guard or session.
@MainActor
@Observable
final class RealtimeHomeModel {
    var destination: RealtimeDestination
    let audioSession: any RealtimeAudioSession
    let sessionGuard: RealtimeSessionGuard

    init(
        destination: RealtimeDestination = .conversation,
        audioSession: any RealtimeAudioSession =
            AVAudioSessionRealtimeAudioSession(),
        sessionGuard: RealtimeSessionGuard = RealtimeSessionGuard(),
    ) {
        self.destination = destination
        self.audioSession = audioSession
        self.sessionGuard = sessionGuard
    }

    func isVisible(_ destination: RealtimeDestination) -> Bool {
        self.destination == destination
    }

    func select(_ destination: RealtimeDestination) {
        self.destination = destination
    }

    func deactivateAudio() async {
        await audioSession.deactivate()
    }

    func dispose() async {
        await audioSession.dispose()
        sessionGuard.dispose()
    }
}
