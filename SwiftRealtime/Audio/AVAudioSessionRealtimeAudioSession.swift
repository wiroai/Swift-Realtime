import AVFoundation
import Foundation
import os
import UIKit

/// Configures the shared `AVAudioSession` and publishes route /
/// interruption events. Features never touch the session directly.
final class AVAudioSessionRealtimeAudioSession:
    RealtimeAudioSession, @unchecked Sendable
{
    let interruptions: AsyncStream<RealtimeAudioInterruption>
    let becomingNoisy: AsyncStream<Void>
    let routeChanges: AsyncStream<Void>

    private let interruptionContinuation:
        AsyncStream<RealtimeAudioInterruption>.Continuation
    private let becomingNoisyContinuation:
        AsyncStream<Void>.Continuation
    private let routeChangeContinuation:
        AsyncStream<Void>.Continuation
    private let lock = OSAllocatedUnfairLock(initialState: false)
    private var observers: [NSObjectProtocol] = []

    /// A healthy `setActive` returns in well under a second; on device
    /// a wedged media server has held it indefinitely. Long enough to
    /// ride out a slow route switch, short enough that the caller's
    /// spinner ends with an answer.
    private static let activationTimeout: Duration = .seconds(8)

    init() {
        let interruption = AsyncStream<RealtimeAudioInterruption>
            .makeStream()
        let noisy = AsyncStream<Void>.makeStream()
        let routes = AsyncStream<Void>.makeStream()
        interruptions = interruption.stream
        interruptionContinuation = interruption.continuation
        becomingNoisy = noisy.stream
        becomingNoisyContinuation = noisy.continuation
        routeChanges = routes.stream
        routeChangeContinuation = routes.continuation
        bindNotifications()
    }

    func prepare(
        _ profile: RealtimeAudioProfile,
    ) async -> AudioPreparationResult {
        if lock.withLock({ $0 }) {
            return .unavailable
        }
        if profile.requiresMicrophone {
            let permission = await requestMicrophonePermission()
            if permission != .ready {
                return permission
            }
        }
        // setActive from a background executor can wait forever on
        // device; the main thread is what AVAudioSession actually
        // services. Bound it so a wedged session cannot own the
        // spinner.
        do {
            return try await withThrowingTaskGroup(
                of: AudioPreparationResult.self,
            ) { group in
                group.addTask { @MainActor in
                    self.activateOnMain(profile)
                }
                group.addTask {
                    try await Task.sleep(for: Self.activationTimeout)
                    throw AudioFailure.sessionActivationTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            return .activationDenied
        }
    }

    @MainActor
    private func activateOnMain(
        _ profile: RealtimeAudioProfile,
    ) -> AudioPreparationResult {
        do {
            let session = AVAudioSession.sharedInstance()
            try configure(session, for: profile)
            try session.setActive(
                true,
                options: .notifyOthersOnDeactivation,
            )
            return .ready
        } catch {
            return .activationDenied
        }
    }

    func deactivate() async {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation,
        )
    }

    func openSystemSettings() async -> Bool {
        await openSettingsOnMain()
    }

    @MainActor
    private func openSettingsOnMain() async -> Bool {
        guard let url = SystemSettingsLink.url else {
            return false
        }
        return await UIApplication.shared.open(url)
    }

    func dispose() async {
        if lock.withLock({ disposed in
            if disposed {
                return true
            }
            disposed = true
            return false
        }) {
            return
        }
        await deactivate()
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        interruptionContinuation.finish()
        becomingNoisyContinuation.finish()
        routeChangeContinuation.finish()
    }

    private func bindNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main,
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            },
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main,
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            },
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main,
            ) { [weak self] _ in
                self?.routeChangeContinuation.yield(())
            },
        )
    }

    private func handleInterruption(_ notification: Notification) {
        let raw = notification.userInfo?[
            AVAudioSessionInterruptionTypeKey,
        ] as? UInt
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            return
        }
        switch type {
        case .began:
            interruptionContinuation.yield(.began)
        case .ended:
            interruptionContinuation.yield(.ended)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        routeChangeContinuation.yield(())
        let raw = notification.userInfo?[
            AVAudioSessionRouteChangeReasonKey,
        ] as? UInt
        guard let raw,
              let reason = AVAudioSession.RouteChangeReason(
                  rawValue: raw,
              )
        else {
            return
        }
        if reason == .oldDeviceUnavailable {
            becomingNoisyContinuation.yield(())
        }
    }

    private func requestMicrophonePermission() async
        -> AudioPreparationResult
    {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .ready
        case .denied:
            return .permissionPermanentlyDenied
        case .undetermined:
            break
        @unknown default:
            return .permissionDenied
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .ready : .permissionDenied
    }

    private func configure(
        _ session: AVAudioSession,
        for profile: RealtimeAudioProfile,
    ) throws {
        switch profile {
        case .conversation, .transcription:
            // Voice-processing path: `measurement` turns off OS
            // input processing and on real devices the microphone
            // comes through near-silent.
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .defaultToSpeaker],
            )
            try session.setPreferredSampleRate(
                Double(AudioConstants.sampleRateHz),
            )
            try session.setPreferredIOBufferDuration(
                AudioConstants.preferredIOBufferDuration,
            )
        case .speech:
            // No category options: `playback` reaches Bluetooth and
            // AirPlay on its own, and naming those options is only
            // legal with `playAndRecord`.
            try session.setCategory(.playback, mode: .spokenAudio)
        }
    }
}
