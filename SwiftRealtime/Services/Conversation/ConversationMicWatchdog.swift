import Foundation
import os

/// Notices when microphone capture dies.
///
/// Healthy capture produces fifty chunks a second no matter how quiet
/// the room is, so a few silent seconds can only mean the pipeline
/// broke. The stall callback is pure timing.
///
/// Chunks are noted on the capture thread; the deadline is checked
/// from a timer task. Both touch the same instant, so it sits behind
/// a lock.
final class ConversationMicWatchdog: @unchecked Sendable {
    private struct State {
        var lastChunkAt: ContinuousClock.Instant
        var watchdog: Task<Void, Never>?
        var disposed = false
    }

    private let onStall: @Sendable () -> Void
    private let stallTimeout: Duration
    private let clock: any RealtimeClock
    private let state: OSAllocatedUnfairLock<State>

    init(
        onStall: @escaping @Sendable () -> Void,
        stallTimeout: Duration = .seconds(3),
        clock: any RealtimeClock = ContinuousClock(),
    ) {
        self.onStall = onStall
        self.stallTimeout = stallTimeout
        self.clock = clock
        state = OSAllocatedUnfairLock(
            initialState: State(lastChunkAt: clock.now),
        )
    }

    /// A chunk arrived; muted capture legitimately delivers nothing,
    /// so the caller also marks the microphone alive while muted.
    func markAlive() {
        let now = clock.now
        state.withLock { $0.lastChunkAt = now }
    }

    func start() {
        if state.withLock(\.disposed) {
            return
        }
        stop()
        let tick = watchdogTick
        let clock = clock
        let task = Task { [weak self] in
            // A sleep only throws when the timer was stopped, and a
            // stopped timer must not report the silence that follows.
            while (try? await clock.sleep(for: tick)) != nil {
                self?.checkStall()
            }
        }
        // Re-checked under the lock: a dispose that landed between
        // the guard above and here must not leave a live timer.
        let disposed = state.withLock { state in
            if state.disposed {
                return true
            }
            state.watchdog = task
            state.lastChunkAt = clock.now
            return false
        }
        if disposed {
            task.cancel()
        }
    }

    func stop() {
        let task = state.withLock { state in
            let task = state.watchdog
            state.watchdog = nil
            return task
        }
        task?.cancel()
    }

    func dispose() {
        state.withLock { $0.disposed = true }
        stop()
    }

    /// Half the timeout, so a stall is reported within one and a
    /// half timeouts at worst, but never faster than the mic can
    /// plausibly recover.
    private var watchdogTick: Duration {
        let half = stallTimeout / 2
        return half < .milliseconds(100)
            ? .milliseconds(100)
            : half
    }

    private func checkStall() {
        let now = clock.now
        let stalled = state.withLock { state in
            !state.disposed
                && now - state.lastChunkAt >= stallTimeout
        }
        if stalled {
            onStall()
        }
    }
}
