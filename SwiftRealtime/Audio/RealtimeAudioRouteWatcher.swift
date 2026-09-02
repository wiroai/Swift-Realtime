import Foundation
import os

/// Owns the audio subscriptions that can force a realtime session to
/// end, and reports them as intent rather than raw platform events.
///
/// An interruption and an unplugged output mean the same thing to a
/// caller — stop now — so they collapse into `onShouldStop`. Whether
/// the session can act on that stays with the caller.
final class RealtimeAudioRouteWatcher: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(
        initialState: [Task<Void, Never>](),
    )

    init(
        audioSession: any RealtimeAudioSession,
        playbackFailures: AsyncStream<AudioFailure>,
        onShouldStop: @escaping @Sendable () -> Void,
        onRouteChanged: @escaping @Sendable () -> Void,
        onPlaybackFailure: @escaping @Sendable (AudioFailure) -> Void,
    ) {
        let started = [
            Task {
                for await interruption in audioSession.interruptions
                    where interruption == .began
                {
                    onShouldStop()
                }
            },
            Task {
                for await _ in audioSession.becomingNoisy {
                    onShouldStop()
                }
            },
            Task {
                for await _ in audioSession.routeChanges {
                    onRouteChanged()
                }
            },
            Task {
                for await failure in playbackFailures {
                    onPlaybackFailure(failure)
                }
            },
        ]
        lock.withLock { $0 = started }
    }

    func dispose() async {
        let tasks = lock.withLock { tasks -> [Task<Void, Never>] in
            let snapshot = tasks
            tasks = []
            return snapshot
        }
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }
}
