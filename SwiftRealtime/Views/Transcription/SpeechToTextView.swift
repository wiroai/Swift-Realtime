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
                .navigationTitle(TranscriptionCopy.emptyTitle)
                .navigationBarTitleDisplayMode(.large)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
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
            } description: {
                Text(connectingCaption)
            }
        } else if model.state.sessionState == .failure,
                  let message = model.state.errorMessage,
                  model.state.transcript.isEmpty
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
        } else if !model.state.transcript.isEmpty {
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
                                    Task {
                                        await model.openSystemSettings()
                                    }
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
                    proxy.scrollTo(
                        "transcript-end",
                        anchor: .bottom,
                    )
                }
            }
        } else {
            ContentUnavailableView(
                TranscriptionCopy.emptyTitle,
                systemImage: "waveform",
                description: Text(TranscriptionCopy.emptyDetail),
            )
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
        ToolbarItem(placement: .automatic) {
            accuracyMenu
        }
        if model.state.isLive {
            ToolbarItem(placement: .automatic) {
                Button(
                    model.state.muted
                        ? TranscriptionCopy.unmute
                        : TranscriptionCopy.mute,
                    systemImage: model.state.muted
                        ? "mic.slash.fill"
                        : "mic.fill",
                ) {
                    model.setMuted(!model.state.muted)
                }
            }
        }
        if !model.state.transcript.isEmpty {
            ToolbarItem(placement: .automatic) {
                Button(
                    TranscriptionCopy.copy,
                    systemImage: "doc.on.doc",
                ) {
                    UIPasteboard.general.string =
                        model.state.transcript
                }
                .accessibilityIdentifier("copy-transcript")
            }
        }
        if model.state.canClearTranscript {
            ToolbarItem(placement: .automatic) {
                Button(
                    TranscriptionCopy.clear,
                    systemImage: "trash",
                ) {
                    model.clearTranscript()
                }
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

    @ViewBuilder
    private var primaryControl: some View {
        if model.state.showsConnecting {
            ProgressView()
        } else if model.state.isLive || model.state.isEnding {
            Button(
                TranscriptionCopy.stop,
                systemImage: "stop.fill",
            ) {
                Task { await model.stop() }
            }
            .disabled(model.state.isEnding)
        } else {
            Button(
                TranscriptionCopy.start,
                systemImage: "mic.fill",
            ) {
                Task { await model.start() }
            }
            .disabled(!model.canStart)
        }
    }

    private var accuracyMenu: some View {
        Menu {
            ForEach(accuracyOptions, id: \.self) { option in
                Button(TranscriptionFields.displayName(option)) {
                    model.selectAccuracy(option)
                }
            }
        } label: {
            Label(
                TranscriptionFields.displayName(model.accuracy),
                systemImage: "gauge.with.needle",
            )
        }
        .disabled(!model.canChangeAccuracy)
        .accessibilityIdentifier("field-transcriptionDelay")
    }

    private var accuracyOptions: [String] {
        TranscriptionFields.delay(in: model.model)?
            .options.map(\.value) ?? []
    }

    private var connectingCaption: String {
        TranscriptionConnectProgress.caption(
            for: model.state.sessionState,
        ) ?? TranscriptionCopy.connecting
    }

    private var subtitle: String {
        if model.state.showsConnecting || model.state.isEnding {
            return connectingCaption
        }
        if model.state.isLive {
            return formatElapsed(model.state.elapsed)
        }
        return TranscriptionFields.displayName(model.accuracy)
    }
}

private func formatElapsed(_ elapsed: Duration) -> String {
    let seconds = Int(elapsed.components.seconds)
    let minutes = seconds / 60
    let remainder = seconds % 60
    return String(format: "%d:%02d", minutes, remainder)
}
