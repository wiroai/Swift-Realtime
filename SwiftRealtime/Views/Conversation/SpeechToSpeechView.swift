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
                .navigationTitle(ConversationCopy.emptyTitle)
                .navigationBarTitleDisplayMode(.large)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showsSettings) {
                    ConversationSettingsView(model: model)
                }
                .alert(
                    SystemSettingsCopy.alertTitle,
                    isPresented: settingsAlertPresented,
                ) {
                    Button(SystemSettingsCopy.open) {
                        Task { await model.openSystemSettings() }
                    }
                    Button("OK", role: .cancel) {}
                } message: {
                    if let message = model.state.errorMessage {
                        Text(message)
                    }
                }
        }
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
        if model.state.showsConnecting {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text(connectingCaption)
            }
        } else if model.displayedStage == .failed,
                  let message = model.state.errorMessage
        {
            ContentUnavailableView {
                Label(
                    message,
                    systemImage: "exclamationmark.triangle",
                )
            } description: {
                EmptyView()
            } actions: {
                if model.state.canOpenSystemSettings {
                    Button(SystemSettingsCopy.open) {
                        Task { await model.openSystemSettings() }
                    }
                    .accessibilityIdentifier(
                        "open-settings-control",
                    )
                }
            }
        } else if hasTranscripts {
            List {
                if !model.state.userTranscript.isEmpty {
                    Section(ConversationCopy.you) {
                        Text(model.state.userTranscript)
                    }
                }
                if !model.state.aiTranscript.isEmpty {
                    Section(ConversationCopy.assistant) {
                        Text(model.state.aiTranscript)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                ConversationCopy.emptyTitle,
                systemImage: "bubble.left.and.bubble.right",
                description: Text(ConversationCopy.emptyDetail),
            )
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
            voiceMenu
        }
        if model.displayedStage == .live {
            ToolbarItem(placement: .automatic) {
                Button(
                    model.state.muted
                        ? ConversationCopy.unmute
                        : ConversationCopy.mute,
                    systemImage: model.state.muted
                        ? "mic.slash.fill"
                        : "mic.fill",
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
        ToolbarItem(placement: .automatic) {
            Button(
                ConversationCopy.settings,
                systemImage: "gearshape",
            ) {
                showsSettings = true
            }
        }
        if model.state.canOpenSystemSettings {
            ToolbarItem(placement: .automatic) {
                Button(
                    SystemSettingsCopy.open,
                    systemImage: "mic.slash.circle",
                ) {
                    Task { await model.openSystemSettings() }
                }
                .accessibilityIdentifier("open-settings-control")
            }
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if model.state.showsConnecting {
            ProgressView()
        } else if model.displayedStage == .live
            || model.displayedStage == .ending
        {
            Button(
                ConversationCopy.stop,
                systemImage: "stop.fill",
            ) {
                Task { await model.stop() }
            }
            .disabled(model.displayedStage == .ending)
        } else {
            Button(
                ConversationCopy.start,
                systemImage: "mic.fill",
            ) {
                Task { await model.start() }
            }
            .disabled(!model.canStart)
        }
    }

    private var voiceMenu: some View {
        Menu {
            ForEach(voiceOptions, id: \.self) { option in
                Button(ConversationFields.displayName(option)) {
                    Task { await model.selectVoice(option) }
                }
            }
        } label: {
            Label(
                ConversationFields.displayName(model.voice),
                systemImage: "waveform",
            )
        }
        .disabled(!model.canChangeVoice)
        .accessibilityIdentifier("field-voice")
    }

    private var voiceOptions: [String] {
        ConversationFields.voice(in: model.model)?
            .options.map(\.value) ?? []
    }

    private var settingsAlertPresented: Binding<Bool> {
        Binding(
            get: { model.state.showsSystemSettingsAlert },
            set: { presented in
                if !presented {
                    model.dismissSystemSettingsAlert()
                }
            },
        )
    }

    private var connectingCaption: String {
        ConversationConnectProgress.caption(
            for: model.state.sessionState,
        ) ?? ConversationCopy.connecting
    }

    private var subtitle: String {
        if model.state.showsConnecting {
            return connectingCaption
        }
        if model.displayedStage == .live
            || model.displayedStage == .ending
        {
            return formatElapsed(model.state.elapsed)
        }
        return ConversationFields.displayName(model.voice)
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
                    optionTitle: ConversationFields.displayName,
                )
            }
            .navigationTitle(ConversationCopy.settings)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(!canEditSettings)
        }
    }

    private var canEditSettings: Bool {
        model.displayedStage == .ready
            || model.displayedStage == .failed
    }
}

private func formatElapsed(_ elapsed: Duration) -> String {
    let seconds = Int(elapsed.components.seconds)
    let minutes = seconds / 60
    let remainder = seconds % 60
    return String(format: "%d:%02d", minutes, remainder)
}
