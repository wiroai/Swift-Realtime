import SwiftUI

/// The stages the conversation and transcription screens draw the
/// same way. Each is a `ContentUnavailableView`, so the system owns
/// the layout; the feature owns when to show which.
enum SessionStage {
    /// A tap is being answered, or a live task is being rebuilt.
    static var connecting: some View {
        ContentUnavailableView {
            ProgressView()
        }
    }

    /// Nothing has been said yet.
    static func idle(systemImage: String) -> some View {
        ContentUnavailableView {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
        }
    }

    /// Live, nothing to show yet: one status word.
    static func listening(muted: Bool) -> some View {
        ContentUnavailableView(
            muted ? SharedCopy.muted : SharedCopy.listening,
            systemImage: muted ? "mic.slash" : "waveform",
        )
    }

    /// One line, plus the way out when the microphone is denied.
    static func failure(
        _ message: String,
        canOpenSettings: Bool,
        openSettings: @escaping @MainActor () async -> Void,
    ) -> some View {
        ContentUnavailableView {
            Label(message, systemImage: "exclamationmark.triangle")
        } description: {
            EmptyView()
        } actions: {
            if canOpenSettings {
                OpenSettingsButton(openSettings: openSettings)
            }
        }
    }
}

struct OpenSettingsButton: View {
    let openSettings: @MainActor () async -> Void

    var body: some View {
        Button(SystemSettingsCopy.open) {
            Task { await openSettings() }
        }
        .accessibilityIdentifier("open-settings-control")
    }
}

extension View {
    /// The one-time alert for a permanently denied microphone.
    func microphoneAccessAlert(
        isPresented: Bool,
        message: String?,
        openSettings: @escaping @MainActor () async -> Void,
        onDismiss: @escaping @MainActor () -> Void,
    ) -> some View {
        alert(
            SystemSettingsCopy.alertTitle,
            isPresented: .dismissal(
                isPresented: isPresented,
                onDismiss: onDismiss,
            ),
        ) {
            Button(SystemSettingsCopy.open) {
                Task { await openSettings() }
            }
            Button(SharedCopy.ok, role: .cancel) {}
        } message: {
            if let message {
                Text(message)
            }
        }
    }
}
