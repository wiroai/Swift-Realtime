import SwiftUI
import UIKit

struct SpeechToTextView: View {
    let credentials: WiroCredentials
    let audioSession: any RealtimeAudioSession
    let sessionGuard: RealtimeSessionGuard
    let isVisible: Bool

    @State private var model: SpeechToTextViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(
        credentials: WiroCredentials,
        audioSession: any RealtimeAudioSession,
        sessionGuard: RealtimeSessionGuard,
        isVisible: Bool,
        model: SpeechToTextViewModel? = nil,
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
                .navigationTitle(TranscriptionCopy.title)
                .navigationBarTitleDisplayMode(.large)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
                .alert(
                    SystemSettingsCopy.alertTitle,
                    isPresented: .dismissal(
                        isPresented: model.state.showsSystemSettingsAlert,
                        onDismiss: model.dismissSystemSettingsAlert,
                    ),
                ) {
                    Button(SystemSettingsCopy.open) {
                        Task { await model.openSystemSettings() }
                    }
                    Button(SharedCopy.ok, role: .cancel) {}
                } message: {
                    if let message = model.state.errorMessage {
                        Text(message)
                    }
                }
        }
        .sensoryFeedback(trigger: model.state.isLive) { _, live in
            live ? .start : .stop
        }
        .accessibilityIdentifier(
            isVisible
                ? "transcription-visible"
                : "transcription-hidden",
        )
        .onChange(of: isVisible) { _, visible in
            if !visible {
                Task { await model.stop() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await model.stop() }
            }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        if model.state.showsConnecting {
            ContentUnavailableView {
                ProgressView()
            }
        } else if model.state.sessionState == .failure,
                  let message = model.state.errorMessage,
                  model.state.transcript.isEmpty
        {
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } description: {
                EmptyView()
            } actions: {
                if model.state.canOpenSystemSettings {
                    Button(SystemSettingsCopy.open) {
                        Task { await model.openSystemSettings() }
                    }
                    .accessibilityIdentifier("open-settings-control")
                }
            }
        } else if !model.state.transcript.isEmpty {
            transcriptList
        } else if model.state.isLive {
            ContentUnavailableView(
                model.state.muted
                    ? TranscriptionCopy.muted
                    : TranscriptionCopy.listening,
                systemImage: model.state.muted ? "mic.slash" : "waveform",
            )
        } else {
            ContentUnavailableView {
                Image(systemName: "text.quote")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List {
                if model.state.sessionState == .failure,
                   let message = model.state.errorMessage
                {
                    Section {
                        Label(
                            message,
                            systemImage: "exclamationmark.triangle",
                        )
                        if model.state.canOpenSystemSettings {
                            Button(SystemSettingsCopy.open) {
                                Task { await model.openSystemSettings() }
                            }
                            .accessibilityIdentifier(
                                "open-settings-control",
                            )
                        }
                    }
                }
                Section {
                    Text(model.state.transcript)
                        .textSelection(.enabled)
                        .id("transcript-end")
                }
            }
            .onChange(of: model.state.transcript) { _, _ in
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.state.showsConnecting {
            ToolbarItem(placement: .cancellationAction) {
                Button(TranscriptionCopy.cancel) {
                    Task { await model.stop() }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            primaryControl
        }
        if model.canChangeAccuracy {
            ToolbarItem(placement: .automatic) {
                accuracyMenu
            }
        }
        if model.state.isLive {
            ToolbarItem(placement: .automatic) {
                Button(
                    model.state.muted
                        ? TranscriptionCopy.unmute
                        : TranscriptionCopy.mute,
                    systemImage: model.state.muted
                        ? "mic.slash.fill"
                        : "mic",
                ) {
                    model.setMuted(!model.state.muted)
                }
            }
        }
        if !model.state.transcript.isEmpty {
            ToolbarItem(placement: .automatic) {
                transcriptMenu
            }
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if model.state.showsConnecting {
            ProgressView()
        } else if model.state.isLive || model.state.isEnding {
            Button(TranscriptionCopy.stop) {
                Task { await model.stop() }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.state.isEnding)
        } else {
            Button(TranscriptionCopy.start) {
                Task { await model.start() }
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.canStart)
        }
    }

    private var accuracyMenu: some View {
        Menu {
            Picker(TranscriptionCopy.accuracy, selection: accuracySelection) {
                ForEach(accuracyOptions, id: \.self) { option in
                    Text(OptionTitle.capitalized(option)).tag(option)
                }
            }
        } label: {
            Text(OptionTitle.capitalized(model.accuracy))
        }
        .accessibilityLabel(TranscriptionCopy.accuracy)
        .accessibilityValue(OptionTitle.capitalized(model.accuracy))
        .accessibilityIdentifier("field-transcriptionDelay")
    }

    private var transcriptMenu: some View {
        Menu(TranscriptionCopy.more, systemImage: "ellipsis.circle") {
            Button(TranscriptionCopy.copy, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = model.state.transcript
            }
            .accessibilityIdentifier("copy-transcript")
            if model.state.canClearTranscript {
                Button(
                    TranscriptionCopy.clear,
                    systemImage: "trash",
                    role: .destructive,
                ) {
                    model.clearTranscript()
                }
            }
        }
    }

    private var accuracySelection: Binding<String> {
        Binding(
            get: { model.accuracy },
            set: { model.selectAccuracy($0) },
        )
    }

    private var accuracyOptions: [String] {
        TranscriptionFields.delay(in: model.model)?
            .options.map(\.value) ?? []
    }

    private var subtitle: String {
        model.state.isLive || model.state.isEnding
            ? model.state.elapsed.clockText
            : ""
    }
}
