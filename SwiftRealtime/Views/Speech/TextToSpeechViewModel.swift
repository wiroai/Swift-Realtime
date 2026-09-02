import Foundation
import Observation

/// Projects a text-to-speech session onto view state.
///
/// Commands go to `sessionService`. This type only narrows the
/// snapshot to what the screen draws.
@MainActor
@Observable
final class TextToSpeechViewModel {
    let sessionService: any SpeechSessionController
    private(set) var state: TextToSpeechState
    private let dependencies: RealtimeSessionDependencies?
    private let audio: AVAudioEnginePcmAudio?
    private var snapshotTask: Task<Void, Never>?
    private var disposed = false

    /// Roughly ten minutes of 20 ms PCM. The model sends the whole
    /// synthesis faster than realtime; dropping the tail would
    /// cut the speech short.
    static let playbackQueueCapacityInChunks = 2500

    init(
        sessionService: any SpeechSessionController,
        dependencies: RealtimeSessionDependencies? = nil,
        audio: AVAudioEnginePcmAudio? = nil,
    ) {
        self.sessionService = sessionService
        self.dependencies = dependencies
        self.audio = audio
        state = TextToSpeechState(
            selectedModel: sessionService.snapshot.selectedModel,
        )
        apply(sessionService.snapshot)
        let snapshots = sessionService.snapshots
        snapshotTask = Task { @MainActor [weak self] in
            for await snapshot in snapshots {
                self?.apply(snapshot)
            }
        }
    }

    /// Wires the billed session stack. Reaching the tab does not
    /// start a task; Play in the toolbar does.
    static func live(
        credentials: WiroCredentials,
        audioSession: any RealtimeAudioSession,
        sessionGuard: RealtimeSessionGuard,
    ) -> TextToSpeechViewModel {
        let dependencies = RealtimeSessionDependencies(
            credentials: credentials,
            readyTimeout: .seconds(120),
        )
        let audio = AVAudioEnginePcmAudio(
            playerQueueCapacityInChunks:
            playbackQueueCapacityInChunks,
        )
        let service = TextToSpeechSessionService(
            audioSession: audioSession,
            apiClient: dependencies.apiClient,
            sessionFactory: { taskId, taskToken in
                dependencies.createSession(
                    taskId: taskId,
                    taskToken: taskToken,
                )
            },
            player: audio.player,
            sessionGuard: sessionGuard,
        )
        return TextToSpeechViewModel(
            sessionService: service,
            dependencies: dependencies,
            audio: audio,
        )
    }

    var parameters: ModelParameterValues {
        sessionService.parameters
    }

    var sessionGuard: RealtimeSessionGuard {
        sessionService.sessionGuard
    }

    var prompt: String {
        get { sessionService.prompt }
        set { sessionService.prompt = newValue }
    }

    var canStart: Bool {
        guard state.sessionState.canStart else {
            return false
        }
        guard let lease = sessionGuard.currentLease else {
            return true
        }
        return lease.owner == .speech
    }

    var canChangeModel: Bool {
        state.sessionState.isIdleLike
    }

    func selectModel(_ model: ModelDefinition) {
        if disposed {
            return
        }
        sessionService.selectModel(model)
    }

    func setParameter(_ value: String, for id: String) {
        if disposed {
            return
        }
        sessionService.setParameter(value, for: id)
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

    private func apply(_ snapshot: SpeechSessionSnapshot) {
        if disposed {
            return
        }
        state.selectedModel = snapshot.selectedModel
        state.sessionState = snapshot.sessionState
        state.elapsed = snapshot.elapsed
        state.errorMessage = snapshot.errorMessage
    }
}
