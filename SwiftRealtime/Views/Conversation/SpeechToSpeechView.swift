import SwiftUI

struct SpeechToSpeechView: View {
    let credentials: WiroCredentials
    let audioSession: any RealtimeAudioSession
    let sessionGuard: RealtimeSessionGuard
    let isVisible: Bool

    @State private var model: SpeechToSpeechViewModel
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase

    init(
        credentials: WiroCredentials,
        audioSession: any RealtimeAudioSession,
        sessionGuard: RealtimeSessionGuard,
        isVisible: Bool,
        model: SpeechToSpeechViewModel? = nil,
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
                .navigationTitle(ConversationCopy.title)
                .navigationBarTitleDisplayMode(.large)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showsSettings) {
                    ConversationSettingsView(model: model)
                }
                .microphoneAccessAlert(
                    isPresented: model.state.showsSystemSettingsAlert,
                    message: model.state.errorMessage,
                    openSettings: model.openSystemSettings,
                    onDismiss: model.dismissSystemSettingsAlert,
                )
        }
        .sensoryFeedback(trigger: isLive) { _, live in
            live ? .start : .stop
        }
        .onScreenTouch { model.noteScreenTouch() }
        .accessibilityIdentifier(
            isVisible ? "conversation-visible" : "conversation-hidden",
        )
        .onChange(of: isVisible) { _, visible in
            Task {
                if visible {
                    await model.resume()
                } else {
                    await model.suspend()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if phase == .active, isVisible {
                    await model.resume()
                } else if phase == .background {
                    // `inactive` is Control Center, banners, and
                    // audio-session flips — not leaving the tab.
                    // Treating it as suspend kills a Run mid-flight
                    // when grace is zero.
                    await model.suspend()
                }
            }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        if model.state.showsConnecting
            || (model.state.isRestoring && !hasTranscripts)
        {
            SessionStage.connecting
        } else if model.displayedStage == .failed,
                  let message = model.state.errorMessage
        {
            SessionStage.failure(
                message,
                canOpenSettings: model.state.canOpenSystemSettings,
                openSettings: model.openSystemSettings,
            )
        } else if hasTranscripts {
            transcriptList
        } else if isLive {
            SessionStage.listening(muted: model.state.muted)
        } else {
            SessionStage.idle(systemImage: "bubble.left.and.bubble.right")
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List {
                if !model.state.userTranscript.isEmpty {
                    Section(ConversationCopy.you) {
                        Text(model.state.userTranscript)
                            .textSelection(.enabled)
                    }
                }
                if !model.state.aiTranscript.isEmpty {
                    Section(ConversationCopy.assistant) {
                        Text(model.state.aiTranscript)
                            .textSelection(.enabled)
                            .id("assistant-end")
                    }
                }
            }
            .onChange(of: model.state.aiTranscript) { _, _ in
                proxy.scrollTo("assistant-end", anchor: .bottom)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.state.showsConnecting {
            ToolbarItem(placement: .cancellationAction) {
                Button(ConversationCopy.cancel) {
                    Task { await model.stop() }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            primaryControl
        }
        ToolbarItem(placement: .automatic) {
            if model.state.isRestoring {
                ProgressView()
                    .accessibilityLabel(ConversationCopy.voice)
                    .accessibilityIdentifier("field-voice-restoring")
            } else {
                voiceMenu
            }
        }
        if isLive, !model.state.isRestoring {
            ToolbarItem(placement: .automatic) {
                Button(
                    model.state.muted
                        ? ConversationCopy.unmute
                        : ConversationCopy.mute,
                    systemImage: model.state.muted
                        ? "mic.slash.fill"
                        : "mic",
                ) {
                    model.setMuted(!model.state.muted)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(
                    ConversationCopy.interrupt,
                    systemImage: "speaker.slash",
                ) {
                    model.interruptAssistant()
                }
            }
        }
        if model.canEditSettings {
            ToolbarItem(placement: .automatic) {
                Button(
                    ConversationCopy.settings,
                    systemImage: "gearshape",
                ) {
                    showsSettings = true
                }
            }
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if model.state.showsConnecting {
            ProgressView()
        } else if isLive || model.displayedStage == .ending {
            Button(ConversationCopy.stop) {
                Task { await model.stop() }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.displayedStage == .ending)
        } else {
            Button(ConversationCopy.start) {
                Task { await model.start() }
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.canStart)
        }
    }

    private var voiceMenu: some View {
        Menu {
            Picker(ConversationCopy.voice, selection: voiceSelection) {
                ForEach(voiceOptions, id: \.self) { option in
                    Text(OptionTitle.capitalized(option)).tag(option)
                }
            }
        } label: {
            Text(OptionTitle.capitalized(model.voice))
        }
        .disabled(!model.canChangeVoice)
        .accessibilityLabel(ConversationCopy.voice)
        .accessibilityValue(OptionTitle.capitalized(model.voice))
        .accessibilityIdentifier("field-voice")
    }

    private var voiceSelection: Binding<String> {
        Binding(
            get: { model.voice },
            set: { voice in Task { await model.selectVoice(voice) } },
        )
    }

    private var voiceOptions: [String] {
        ConversationFields.voice(in: model.model)?
            .options.map(\.value) ?? []
    }

    private var subtitle: String {
        isLive || model.displayedStage == .ending
            ? model.state.elapsed.clockText
            : ""
    }

    private var isLive: Bool {
        model.displayedStage == .live
    }

    private var hasTranscripts: Bool {
        !model.state.userTranscript.isEmpty
            || !model.state.aiTranscript.isEmpty
    }
}

struct ConversationSettingsView: View {
    @Bindable var model: SpeechToSpeechViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ModelParameterForm(
                    fields: ConversationFields.settingsFields(
                        in: model.model,
                    ),
                    value: { model.parameters.value(for: $0) ?? "" },
                    setValue: { model.setParameter($0, for: $1) },
                    optionTitle: OptionTitle.capitalized,
                )
            }
            .navigationTitle(ConversationCopy.settings)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(SharedCopy.done) { dismiss() }
                }
            }
            .disabled(!model.canEditSettings)
        }
    }
}
