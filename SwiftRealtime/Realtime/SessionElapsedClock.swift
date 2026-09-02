import Foundation
import os

/// Reports how long a realtime session has been running on a fixed
/// cadence.
///
/// `start` replaces any previous run, so a restarted session cannot
/// leave an orphaned timer behind. The task handle sits under a lock
/// because `stop` is called from whichever thread notices the session
/// ending — the socket's receive callback as often as a Swift task.
final class SessionElapsedClock: @unchecked Sendable {
    let tick: Duration
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(
        initialState: nil,
    )

    var isRunning: Bool {
        task.withLock { $0 != nil }
    }

    init(tick: Duration = .seconds(1)) {
        self.tick = tick
    }

    func start(
        _ onTick: @escaping @Sendable (Duration) -> Void,
    ) {
        let tick = tick
        let replacement = Task {
            var count = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: tick)
                } catch {
                    break
                }
                if Task.isCancelled {
                    break
                }
                count += 1
                onTick(tick * count)
            }
        }
        let previous = task.withLock { task in
            let previous = task
            task = replacement
            return previous
        }
        previous?.cancel()
    }

    func stop() {
        let previous = task.withLock { task in
            let previous = task
            task = nil
            return previous
        }
        previous?.cancel()
    }
}
