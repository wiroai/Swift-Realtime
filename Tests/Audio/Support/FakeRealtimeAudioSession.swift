import Foundation
import os
@testable import SwiftRealtime

final class FakeRealtimeAudioSession:
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

    var preparationResult: AudioPreparationResult = .ready
    var preparedProfiles: [RealtimeAudioProfile] = []
    var deactivateCalls = 0
    var openSystemSettingsCalls = 0
    var systemSettingsAvailable = true

    init(preparationResult: AudioPreparationResult = .ready) {
        self.preparationResult = preparationResult
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
    }

    func emitInterruption(_ value: RealtimeAudioInterruption) {
        interruptionContinuation.yield(value)
    }

    func emitBecomingNoisy() {
        becomingNoisyContinuation.yield(())
    }

    func emitRouteChange() {
        routeChangeContinuation.yield(())
    }

    func prepare(
        _ profile: RealtimeAudioProfile,
    ) async -> AudioPreparationResult {
        preparedProfiles.append(profile)
        return preparationResult
    }

    func deactivate() async {
        deactivateCalls += 1
    }

    func openSystemSettings() async -> Bool {
        openSystemSettingsCalls += 1
        return systemSettingsAvailable
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
        interruptionContinuation.finish()
        becomingNoisyContinuation.finish()
        routeChangeContinuation.finish()
    }
}
