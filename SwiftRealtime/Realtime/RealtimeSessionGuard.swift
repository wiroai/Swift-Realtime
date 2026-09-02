import Foundation
import os

enum RealtimeSessionOwner: Sendable, Equatable, Hashable {
    case conversation
    case transcription
    case speech
}

struct RealtimeSessionLease: Equatable, Hashable, Sendable {
    let owner: RealtimeSessionOwner
    let id: Int
}

final class RealtimeSessionGuard: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let owner: RealtimeSessionOwner
        private var continuation: CheckedContinuation<
            RealtimeSessionLease?,
            Never,
        >?
        var timeoutTask: Task<Void, Never>?

        init(
            owner: RealtimeSessionOwner,
            continuation: CheckedContinuation<
                RealtimeSessionLease?,
                Never,
            >,
        ) {
            self.owner = owner
            self.continuation = continuation
        }

        func complete(_ lease: RealtimeSessionLease?) -> Bool {
            guard let continuation else {
                return false
            }
            self.continuation = nil
            timeoutTask?.cancel()
            continuation.resume(returning: lease)
            return true
        }
    }

    private struct State {
        var lease: RealtimeSessionLease?
        var nextID = 0
        var disposed = false
        var waiters: [Waiter] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How long a screen waits for the previous owner to let go. A
    /// teardown drains queued playback for at most the player's own
    /// drain timeout, so anything slower is a lease that leaked.
    static let defaultAcquireTimeout: Duration = .seconds(5)

    var currentLease: RealtimeSessionLease? {
        state.withLock(\.lease)
    }

    func acquire(
        _ owner: RealtimeSessionOwner,
    ) -> RealtimeSessionLease? {
        state.withLock { state in
            guard !state.disposed, state.lease == nil else {
                return nil
            }
            state.nextID += 1
            let lease = RealtimeSessionLease(
                owner: owner,
                id: state.nextID,
            )
            state.lease = lease
            return lease
        }
    }

    /// Acquires the lease, waiting out another feature's teardown.
    func acquireWhenFree(
        _ owner: RealtimeSessionOwner,
        timeout: Duration = defaultAcquireTimeout,
    ) async -> RealtimeSessionLease? {
        if let lease = acquire(owner) {
            return lease
        }
        if state.withLock(\.disposed) {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let waiter = Waiter(
                owner: owner,
                continuation: continuation,
            )
            waiter.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(waiter, lease: nil)
            }
            state.withLock { $0.waiters.append(waiter) }
            if let lease = acquire(owner) {
                finish(waiter, lease: lease)
            }
        }
    }

    func release(_ lease: RealtimeSessionLease?) {
        let shouldFulfill = state.withLock { state -> Bool in
            guard !state.disposed,
                  let lease,
                  state.lease == lease
            else {
                return false
            }
            state.lease = nil
            return true
        }
        if shouldFulfill {
            fulfillWaiters()
        }
    }

    func dispose() {
        let waiters = state.withLock { state -> [Waiter] in
            state.disposed = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            _ = waiter.complete(nil)
        }
    }

    private func finish(
        _ waiter: Waiter,
        lease: RealtimeSessionLease?,
    ) {
        state.withLock { state in
            state.waiters.removeAll { $0 === waiter }
        }
        _ = waiter.complete(lease)
    }

    private func fulfillWaiters() {
        while true {
            guard let waiter = state.withLock(\.waiters.first) else {
                return
            }
            if state.withLock(\.disposed) {
                finish(waiter, lease: nil)
                continue
            }
            if let lease = acquire(waiter.owner) {
                finish(waiter, lease: lease)
                return
            }
            return
        }
    }
}
