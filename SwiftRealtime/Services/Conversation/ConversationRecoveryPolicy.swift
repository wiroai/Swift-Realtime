import Foundation
import os

/// Retry and auto-restart budgets for a conversation that lost its task.
///
/// A healthy microphone chunk reaching the server is the only signal
/// that both counters should refill — and it arrives on the capture
/// thread while a failure is being handled on a task, so the counters
/// sit behind a lock.
final class ConversationRecoveryPolicy: @unchecked Sendable {
    let maxRetryAttempts: Int
    let retryBaseDelay: Duration
    let autoRestartDelay: Duration
    let maxAutoRestarts: Int
    private let clock: any RealtimeClock

    /// Auto-restart backoff stops doubling here: a backend that is
    /// still down after three cycles is not helped by waiting longer.
    private static let maxAutoRestartBackoffShift = 2

    private struct State {
        var autoRestartTask: Task<Void, Never>?
        var retryAttempt = 0
        var autoRestartCycle = 0
        var disposed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        maxRetryAttempts: Int = 5,
        retryBaseDelay: Duration = .milliseconds(500),
        autoRestartDelay: Duration = .seconds(5),
        maxAutoRestarts: Int = 2,
        clock: any RealtimeClock = ContinuousClock(),
    ) {
        self.maxRetryAttempts = maxRetryAttempts
        self.retryBaseDelay = retryBaseDelay
        self.autoRestartDelay = autoRestartDelay
        self.maxAutoRestarts = maxAutoRestarts
        self.clock = clock
    }

    var retryAttempt: Int {
        state.withLock(\.retryAttempt)
    }

    /// Backoff after the current retry was scheduled: doubles each time.
    var nextRetryDelay: Duration {
        let shift = max(0, retryAttempt - 1)
        return retryBaseDelay * (1 << shift)
    }

    func shouldRetry(
        _ error: Error,
        isReconfiguring: Bool,
    ) -> Bool {
        if isReconfiguring || retryAttempt >= maxRetryAttempts {
            return false
        }
        return isRecoverable(error)
    }

    func isRecoverable(_ error: Error) -> Bool {
        if error is AudioFailure {
            return true
        }
        guard let failure = error as? WiroFailure else {
            return false
        }
        switch failure.code {
        case .serverUnavailable, .networkUnavailable, .requestTimeout,
             .socketConnection, .socketConnectTimeout,
             .streamReadyTimeout:
            return true
        case .authentication, .apiRejected, .rateLimited,
             .cancelled, .malformedResponse, .realtimeProtocol,
             .sessionBusy:
            return false
        }
    }

    func noteRetryScheduled() {
        state.withLock { $0.retryAttempt += 1 }
    }

    /// A microphone chunk reached the server, so both budgets refill.
    func noteHealthy() {
        state.withLock { state in
            state.retryAttempt = 0
            state.autoRestartCycle = 0
        }
    }

    /// A user (or auto-restart) start; in-flight retries reset.
    func resetRetries() {
        state.withLock { $0.retryAttempt = 0 }
    }

    /// Arms a restart. Returns false when the budget is spent.
    func scheduleAutoRestart(
        _ restart: @escaping @Sendable () -> Void,
    ) -> Bool {
        let delay: Duration? = state.withLock { state in
            if state.disposed || state.autoRestartCycle >= maxAutoRestarts {
                return nil
            }
            let shift = min(
                state.autoRestartCycle,
                Self.maxAutoRestartBackoffShift,
            )
            state.autoRestartCycle += 1
            return autoRestartDelay * (1 << shift)
        }
        guard let delay else {
            return false
        }
        let clock = clock
        let task = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard let self, !Task.isCancelled,
                  !self.state.withLock(\.disposed)
            else {
                return
            }
            restart()
        }
        let previous = state.withLock { state in
            let previous = state.autoRestartTask
            state.autoRestartTask = task
            return previous
        }
        previous?.cancel()
        return true
    }

    func cancelAutoRestart() {
        let task = state.withLock { state in
            let task = state.autoRestartTask
            state.autoRestartTask = nil
            return task
        }
        task?.cancel()
    }

    func dispose() {
        state.withLock { $0.disposed = true }
        cancelAutoRestart()
    }
}
