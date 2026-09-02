import SwiftUI

struct TextToSpeechView: View {
    let credentials: WiroCredentials
    let audioSession: any RealtimeAudioSession
    let sessionGuard: RealtimeSessionGuard
    let isVisible: Bool

    @State private var model: TextToSpeechViewModel
    @State private var showsSettings = false
    @FocusState private var promptFocused: Bool
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
        NavigationStack {
            stageContent
                .navigationTitle(SpeechCopy.title)
                .navigationBarTitleDisplayMode(.large)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showsSettings) {
                    SpeechSettingsView(model: model)
                }
        }
        .sensoryFeedback(trigger: model.state.isLive) { _, live in
            live ? .start : .stop
        }
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
        return Form {
            if let message = model.state.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                }
            }
            Section {
                TextField(
                    SpeechCopy.promptPlaceholder,
                    text: $model.prompt,
                    axis: .vertical,
                )
                .lineLimit(8...)
                .focused($promptFocused)
                .disabled(!model.state.canEditPrompt)
                .accessibilityIdentifier("tts-prompt")
            } footer: {
                if !model.prompt.isEmpty {
                    Text(SpeechCopy.characterCount(model.prompt.count))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("tts-character-count")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // The field keeps its own tap; anywhere else on the form ends
        // editing.
        .onTapGesture { promptFocused = false }
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
        if model.canChangeModel {
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
                }
            }
        }
        if promptFocused {
            ToolbarItem(placement: .keyboard) {
                Button(SharedCopy.done) { promptFocused = false }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if model.state.showsConnecting {
            ProgressView()
        } else if model.state.isLive || model.state.isEnding {
            Button(SpeechCopy.stop) {
                Task { await model.stop() }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.state.isEnding)
        } else {
            Button(SpeechCopy.play) {
                promptFocused = false
                Task { await model.start() }
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.canStart || promptIsBlank)
        }
    }

    /// Matches the service's own check so Play never leads to the
    /// empty-prompt failure line.
    private var promptIsBlank: Bool {
        model.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var modelMenu: some View {
        Menu {
            Picker(SpeechCopy.model, selection: modelSelection) {
                ForEach(SpeechFields.models, id: \.modelSlug) { option in
                    Text(option.displayName).tag(option.modelSlug)
                }
            }
        } label: {
            Text(model.state.selectedModel.displayName)
        }
        .accessibilityLabel(SpeechCopy.model)
        .accessibilityValue(model.state.selectedModel.displayName)
        .accessibilityIdentifier("tts-model-selector")
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { model.state.selectedModel.modelSlug },
            set: { slug in
                if let option = SpeechFields.models.first(
                    where: { $0.modelSlug == slug },
                ) {
                    model.selectModel(option)
                }
            },
        )
    }

    private var subtitle: String {
        model.state.isLive || model.state.isEnding
            ? model.state.elapsed.clockText
            : ""
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
                    Button(SharedCopy.done) { dismiss() }
                }
            }
            .disabled(!model.canChangeModel)
        }
    }
}
