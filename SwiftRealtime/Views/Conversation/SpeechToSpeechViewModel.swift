import Foundation
import Observation

/// Projects a conversation session onto view state.
///
/// Commands go to `sessionService`. This type only narrows the
/// snapshot to what the screen draws, plus `reportsConnecting`.
@MainActor
@Observable
final class SpeechToSpeechViewModel {
    let sessionService: any ConversationSessionController
    private(set) var state = SpeechToSpeechState()
    private(set) var voice: String
    private let dependencies: RealtimeSessionDependencies?
    private let audio: AVAudioEnginePcmAudio?
    private var snapshotTask: Task<Void, Never>?
    private var disposed = false
    private var settingsOffer = SystemSettingsOffer()

    init(
        sessionService: any ConversationSessionController,
        dependencies: RealtimeSessionDependencies? = nil,
        audio: AVAudioEnginePcmAudio? = nil,
    ) {
        self.sessionService = sessionService
        self.dependencies = dependencies
        self.audio = audio
        voice = sessionService.parameters.value(
            for: ConversationFields.voiceId,
        ) ?? ConversationConfig.voice
        apply(sessionService.snapshot)
        let snapshots = sessionService.snapshots
        snapshotTask = Task { @MainActor [weak self] in
            for await snapshot in snapshots {
                self?.apply(snapshot)
            }
        }
    }

    /// Wires the billed session stack. Reaching the tab does not start
    /// a task; Start in the toolbar does.
    static func live(
        credentials: WiroCredentials,
        audioSession: any RealtimeAudioSession,
        sessionGuard: RealtimeSessionGuard,
    ) -> SpeechToSpeechViewModel {
        let dependencies = RealtimeSessionDependencies(
            credentials: credentials,
            readyTimeout: .seconds(60),
        )
        let audio = AVAudioEnginePcmAudio()
        let service = SpeechToSpeechSessionService(
            audioSession: audioSession,
            apiClient: dependencies.apiClient,
            sessionFactory: { taskId, taskToken in
                dependencies.createSession(
                    taskId: taskId,
                    taskToken: taskToken,
                )
            },
            recorder: audio.recorder,
            player: audio.player,
            sessionGuard: sessionGuard,
            model: ConversationConfig.model,
            parameters: ConversationConfig.parameterValues(),
            suspendGracePeriod: ConversationConfig.suspendGracePeriod,
            noiseGate: PcmNoiseGate(),
        )
        return SpeechToSpeechViewModel(
            sessionService: service,
            dependencies: dependencies,
            audio: audio,
        )
    }

    var parameters: ModelParameterValues {
        sessionService.parameters
    }

    var model: ModelDefinition {
        sessionService.model
    }

    var sessionGuard: RealtimeSessionGuard {
        sessionService.sessionGuard
    }

    var displayedStage: ConversationStage {
        state.displayedStage
    }

    var canStart: Bool {
        guard displayedStage == .ready || displayedStage == .failed
        else {
            return false
        }
        guard let lease = sessionGuard.currentLease else {
            return true
        }
        return lease.owner == .conversation
    }

    var canChangeVoice: Bool {
        if state.isReconfiguring || state.showsConnecting {
            return false
        }
        return displayedStage == .ready || displayedStage == .live
    }

    func start() async {
        if disposed {
            return
        }
        state.reportsConnecting = true
        await sessionService.start()
    }

    func stop() async {
        await sessionService.stop()
    }

    func selectVoice(_ voice: String) async {
        if voice == self.voice {
            return
        }
        if displayedStage == .live {
            await sessionService.changeVoice(voice)
        } else {
            sessionService.setParameter(
                voice,
                for: ConversationFields.voiceId,
            )
        }
        self.voice = sessionService.parameters.value(
            for: ConversationFields.voiceId,
        ) ?? voice
    }

    func setParameter(_ value: String, for id: String) {
        sessionService.setParameter(value, for: id)
        if id == ConversationFields.voiceId {
            voice = value
        }
    }

    func suspend() async {
        await sessionService.suspend()
    }

    func resume() async {
        await sessionService.resume()
    }

    func setMuted(_ muted: Bool) {
        sessionService.setMuted(muted)
    }

    func interruptAssistant() {
        sessionService.interruptAssistant()
    }

    func noteScreenTouch() {
        if displayedStage == .live {
            sessionService.noteScreenTouch()
        }
    }

    func openSystemSettings() async {
        await sessionService.openSystemSettings()
    }

    func dismissSystemSettingsAlert() {
        if disposed {
            return
        }
        settingsOffer.dismissAlert()
        state.showsSystemSettingsAlert = settingsOffer.showsAlert
    }

    func dispose() async {
        if disposed {
            return
        }
        disposed = true
        snapshotTask?.cancel()
        snapshotTask = nil
        await sessionService.dispose()
        dependencies?.close()
        await audio?.dispose()
    }

    private func apply(_ snapshot: ConversationSessionSnapshot) {
        if disposed {
            return
        }
        let holdsFirstWait: Bool
        switch snapshot.sessionState.conversationStage {
        case .ready, .connecting:
            holdsFirstWait = true
        case .live, .ending, .failed:
            holdsFirstWait = false
        }
        state.sessionState = snapshot.sessionState
        state.elapsed = snapshot.elapsed
        state.userTranscript = snapshot.userTranscript
        state.aiTranscript = snapshot.aiTranscript
        state.muted = snapshot.muted
        state.isReconfiguring = snapshot.isReconfiguring
        state.reportsConnecting = state.reportsConnecting && holdsFirstWait
        state.errorMessage = snapshot.errorMessage
        settingsOffer.apply(
            canOpen: snapshot.canOpenSystemSettings,
        )
        state.canOpenSystemSettings = settingsOffer.canOpen
        state.showsSystemSettingsAlert = settingsOffer.showsAlert
        voice = sessionService.parameters.value(
            for: ConversationFields.voiceId,
        ) ?? voice
    }
}
