import SwiftUI

struct TextToSpeechView: View {
    let credentials: WiroCredentials
    let audioSession: any RealtimeAudioSession
    let sessionGuard: RealtimeSessionGuard
    let isVisible: Bool

    @State private var model: TextToSpeechViewModel
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase

    init(
        credentials: WiroCredentials,
        audioSession: any RealtimeAudioSession,
        sessionGuard: RealtimeSessionGuard,
        isVisible: Bool,
        model: TextToSpeechViewModel? = nil,
    ) {
        self.credentials = credentials
        self.audioSession = audioSession
        self.sessionGuard = sessionGuard
        self.isVisible = isVisible
        _model = State(
            initialValue: model ?? .live(
                credentials: credentials,
                audioSession: audioSession,
                sessionGuard: sessionGuard,
            ),
        )
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            stageContent
                .navigationTitle(SpeechCopy.destinationTitle)
                .navigationBarTitleDisplayMode(.large)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showsSettings) {
                    SpeechSettingsView(model: model)
                }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier(
            isVisible ? "speech-visible" : "speech-hidden",
        )
        .onChange(of: isVisible) { _, visible in
            if !visible {
                Task { await model.stop() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // `inactive` fires for Control Center, banners, and
            // audio-session flips. That is not leaving the tab;
            // treating it as stop kills a Run that Wiro already
            // accepted and leaves the spinner up.
            if phase == .background {
                Task { await model.stop() }
            }
        }
    }

    private var stageContent: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            if let message = model.state.errorMessage {
                Label(
                    message,
                    systemImage: "exclamationmark.triangle",
                )
            }
            TextEditor(text: $model.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .disabled(!model.state.canEditPrompt)
                .id(model.state.selectedModel.modelSlug)
                .overlay(alignment: .topLeading) {
                    if model.prompt.isEmpty {
                        Text(SpeechCopy.promptHint)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("tts-prompt")
            if !model.prompt.isEmpty {
                Text(SpeechCopy.characterCount(model.prompt.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("tts-character-count")
            }
            if model.state.showsConnecting || model.state.isEnding {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.state.showsConnecting {
            ToolbarItem(placement: .cancellationAction) {
                Button(SpeechCopy.cancel) {
                    Task { await model.stop() }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            primaryControl
        }
        ToolbarItem(placement: .automatic) {
            modelMenu
        }
        if !SpeechFields.settingsFields(
            in: model.state.selectedModel,
        ).isEmpty {
            ToolbarItem(placement: .automatic) {
                Button(
                    SpeechCopy.settings,
                    systemImage: "gearshape",
                ) {
                    showsSettings = true
                }
                .disabled(!model.canChangeModel)
            }
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if model.state.showsConnecting {
            ProgressView()
        } else if model.state.isLive || model.state.isEnding {
            Button(SpeechCopy.stop, systemImage: "stop.fill") {
                Task { await model.stop() }
            }
            .disabled(model.state.isEnding)
            .accessibilityLabel(SpeechCopy.stop)
        } else {
            Button(SpeechCopy.play, systemImage: "play.fill") {
                Task { await model.start() }
            }
            .disabled(!model.canStart)
            .accessibilityLabel(SpeechCopy.play)
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(SpeechFields.models, id: \.modelSlug) { option in
                Button(option.displayName) {
                    model.selectModel(option)
                }
            }
        } label: {
            Label(
                model.state.selectedModel.displayName,
                systemImage: "waveform",
            )
        }
        .disabled(!model.canChangeModel)
        .accessibilityIdentifier("tts-model-selector")
        .accessibilityLabel(SpeechCopy.model)
    }

    private var subtitle: String {
        if let caption = SpeechConnectProgress.caption(
            for: model.state.sessionState,
            isPlaying: model.state.isPlaying,
        ) {
            if model.state.isLive {
                return "\(formatElapsed(model.state.elapsed)) · "
                    + caption
            }
            return caption
        }
        return model.state.selectedModel.displayName
    }
}

struct SpeechSettingsView: View {
    @Bindable var model: TextToSpeechViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ModelParameterForm(
                    fields: SpeechFields.settingsFields(
                        in: model.state.selectedModel,
                    ),
                    value: { model.parameters.value(for: $0) ?? "" },
                    setValue: { model.setParameter($0, for: $1) },
                )
            }
            .navigationTitle(SpeechCopy.settings)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(!model.canChangeModel)
        }
    }
}

private func formatElapsed(_ elapsed: Duration) -> String {
    let seconds = Int(elapsed.components.seconds)
    let minutes = seconds / 60
    let remainder = seconds % 60
    return String(format: "%d:%02d", minutes, remainder)
}
