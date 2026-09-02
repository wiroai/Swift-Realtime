import Foundation
import Observation

/// Projects a transcription session onto view state.
///
/// Commands go to `sessionService`. This type only narrows the
/// snapshot to what the screen draws.
@MainActor
@Observable
final class SpeechToTextViewModel {
    let sessionService: any TranscriptionSessionController
    private(set) var state = SpeechToTextState()
    private(set) var accuracy: String
    private let dependencies: RealtimeSessionDependencies?
    private let audio: AVAudioEnginePcmAudio?
    private var snapshotTask: Task<Void, Never>?
    private var disposed = false
    private var settingsOffer = SystemSettingsOffer()

    init(
        sessionService: any TranscriptionSessionController,
        dependencies: RealtimeSessionDependencies? = nil,
        audio: AVAudioEnginePcmAudio? = nil,
    ) {
        self.sessionService = sessionService
        self.dependencies = dependencies
        self.audio = audio
        accuracy = sessionService.parameters.value(
            for: TranscriptionFields.delayId,
        ) ?? "balanced"
        apply(sessionService.snapshot)
        let snapshots = sessionService.snapshots
        snapshotTask = Task { @MainActor [weak self] in
            for await snapshot in snapshots {
                self?.apply(snapshot)
            }
        }
    }

    /// Wires the billed session stack. Reaching the tab does not
    /// start a task; Start in the toolbar does.
    static func live(
        credentials: WiroCredentials,
        audioSession: any RealtimeAudioSession,
        sessionGuard: RealtimeSessionGuard,
    ) -> SpeechToTextViewModel {
        let dependencies = RealtimeSessionDependencies(
            credentials: credentials,
            readyTimeout: .seconds(120),
        )
        let audio = AVAudioEnginePcmAudio()
        let service = SpeechToTextSessionService(
            audioSession: audioSession,
            apiClient: dependencies.apiClient,
            sessionFactory: { taskId, taskToken in
                dependencies.createSession(
                    taskId: taskId,
                    taskToken: taskToken,
                )
            },
            recorder: audio.recorder,
            sessionGuard: sessionGuard,
        )
        return SpeechToTextViewModel(
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

    var canStart: Bool {
        guard state.sessionState.canStart else {
            return false
        }
        guard let lease = sessionGuard.currentLease else {
            return true
        }
        return lease.owner == .transcription
    }

    var canChangeAccuracy: Bool {
        state.sessionState.isIdleLike
    }

    func start() async {
        if disposed {
            return
        }
        await sessionService.start()
    }

    func stop() async {
        await sessionService.stop()
    }

    func setMuted(_ muted: Bool) {
        sessionService.setMuted(muted)
    }

    func selectAccuracy(_ value: String) {
        if value == accuracy {
            return
        }
        sessionService.setParameter(
            value,
            for: TranscriptionFields.delayId,
        )
        accuracy = sessionService.parameters.value(
            for: TranscriptionFields.delayId,
        ) ?? value
    }

    func clearTranscript() {
        sessionService.clearTranscript()
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

    private func apply(_ snapshot: TranscriptionSessionSnapshot) {
        if disposed {
            return
        }
        state.sessionState = snapshot.sessionState
        state.elapsed = snapshot.elapsed
        state.transcript = snapshot.transcript
        state.muted = snapshot.muted
        state.errorMessage = snapshot.errorMessage
        settingsOffer.apply(
            canOpen: snapshot.canOpenSystemSettings,
        )
        state.canOpenSystemSettings = settingsOffer.canOpen
        state.showsSystemSettingsAlert = settingsOffer.showsAlert
        accuracy = sessionService.parameters.value(
            for: TranscriptionFields.delayId,
        ) ?? accuracy
    }
}
