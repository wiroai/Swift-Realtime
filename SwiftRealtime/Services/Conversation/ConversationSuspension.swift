import Foundation
import os

/// Wall-clock hold for a conversation the speaker left the screen of.
///
/// The timer hangs the task up if nobody comes back. A frozen app runs
/// no timers, so `hasLapsed` is the source of truth on resume.
final class ConversationSuspension: @unchecked Sendable {
    private struct State {
        var expireTask: Task<Void, Never>?
        var suspendedAt: ContinuousClock.Instant?
        var disposed = false
    }

    let gracePeriod: Duration
    private let onExpired: @Sendable () -> Void
    private let clock: any RealtimeClock
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        gracePeriod: Duration,
        clock: any RealtimeClock = ContinuousClock(),
        onExpired: @escaping @Sendable () -> Void,
    ) {
        self.gracePeriod = gracePeriod
        self.clock = clock
        self.onExpired = onExpired
    }

    /// A configured zero (or less) means leaving is hanging up.
    var holdsAnything: Bool {
        gracePeriod > .zero
    }

    /// True when no hold is running, or the grace period has passed —
    /// even if the timer never fired.
    var hasLapsed: Bool {
        state.withLock { state in
            guard let suspendedAt = state.suspendedAt else {
                return true
            }
            return clock.now - suspendedAt > gracePeriod
        }
    }

    func begin() {
        if state.withLock(\.disposed) {
            return
        }
        let gracePeriod = gracePeriod
        let clock = clock
        let task = Task { [weak self] in
            try? await clock.sleep(for: gracePeriod)
            guard let self, !Task.isCancelled else {
                return
            }
            self.expire()
        }
        let previous = state.withLock { state in
            let previous = state.expireTask
            state.expireTask = task
            state.suspendedAt = clock.now
            return previous
        }
        previous?.cancel()
    }

    /// Cancels the timer without forgetting when the hold started.
    func cancel() {
        let task = state.withLock { state in
            let task = state.expireTask
            state.expireTask = nil
            return task
        }
        task?.cancel()
    }

    /// Drops the hold entirely: the session is ending or coming back
    /// live.
    func clear() {
        cancel()
        state.withLock { $0.suspendedAt = nil }
    }

    func dispose() {
        state.withLock { $0.disposed = true }
        clear()
    }

    private func expire() {
        let live = state.withLock { state in
            state.expireTask = nil
            return !state.disposed
        }
        if live {
            onExpired()
        }
    }
}
