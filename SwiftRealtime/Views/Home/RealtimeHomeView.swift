import SwiftUI

/// Three destinations stay mounted so a hidden tab can observe
/// `isVisible == false` and drop the microphone instead of billing
/// behind the selected one.
struct RealtimeHomeView: View {
    let credentials: WiroCredentials
    @State private var model: RealtimeHomeModel
    @State private var conversation: SpeechToSpeechViewModel
    @State private var transcription: SpeechToTextViewModel
    @State private var speech: TextToSpeechViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(
        credentials: WiroCredentials,
        model: RealtimeHomeModel = RealtimeHomeModel(),
    ) {
        self.credentials = credentials
        _model = State(initialValue: model)
        _conversation = State(
            initialValue: .live(
                credentials: credentials,
                audioSession: model.audioSession,
                sessionGuard: model.sessionGuard,
            ),
        )
        _transcription = State(
            initialValue: .live(
                credentials: credentials,
                audioSession: model.audioSession,
                sessionGuard: model.sessionGuard,
            ),
        )
        _speech = State(
            initialValue: .live(
                credentials: credentials,
                audioSession: model.audioSession,
                sessionGuard: model.sessionGuard,
            ),
        )
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.destination) {
            Tab(
                RealtimeDestination.conversation.title,
                systemImage: RealtimeDestination.conversation
                    .systemImage,
                value: RealtimeDestination.conversation,
            ) {
                SpeechToSpeechView(
                    credentials: credentials,
                    audioSession: model.audioSession,
                    sessionGuard: model.sessionGuard,
                    isVisible: model.isVisible(.conversation),
                    model: conversation,
                )
            }
            Tab(
                RealtimeDestination.transcription.title,
                systemImage: RealtimeDestination.transcription
                    .systemImage,
                value: RealtimeDestination.transcription,
            ) {
                SpeechToTextView(
                    credentials: credentials,
                    audioSession: model.audioSession,
                    sessionGuard: model.sessionGuard,
                    isVisible: model.isVisible(.transcription),
                    model: transcription,
                )
            }
            Tab(
                RealtimeDestination.speech.title,
                systemImage: RealtimeDestination.speech.systemImage,
                value: RealtimeDestination.speech,
            ) {
                TextToSpeechView(
                    credentials: credentials,
                    audioSession: model.audioSession,
                    sessionGuard: model.sessionGuard,
                    isVisible: model.isVisible(.speech),
                    model: speech,
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await model.deactivateAudio() }
            }
        }
        .onDisappear {
            Task {
                await conversation.dispose()
                await transcription.dispose()
                await speech.dispose()
                await model.dispose()
            }
        }
    }
}

#Preview {
    RealtimeHomeView(
        // swiftlint:disable:next force_try
        credentials: try! WiroEnvironment.fromValues(
            apiKey: "preview",
        ),
    )
    .appAppearance()
}
