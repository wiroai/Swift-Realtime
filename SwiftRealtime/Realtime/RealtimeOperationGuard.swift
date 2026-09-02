import os

/// Invalidates in-flight realtime work whose result is no longer wanted.
///
/// Every asynchronous session operation claims an id through `begin`.
/// Awaits inside that operation must re-check `isCurrent` before touching
/// shared state, because a newer operation — or `dispose` — may have
/// superseded it while the await was suspended.
///
/// `isCurrent` is asked from the capture thread and the socket's
/// receive thread while `begin` runs on a Swift task, so the id and
/// the disposed flag move together under one lock.
final class RealtimeOperationGuard: @unchecked Sendable {
    private struct State {
        var currentID = 0
        var disposed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var current: Int {
        state.withLock(\.currentID)
    }

    var isDisposed: Bool {
        state.withLock(\.disposed)
    }

    @discardableResult
    func begin() -> Int {
        state.withLock { state in
            state.currentID += 1
            return state.currentID
        }
    }

    func isCurrent(_ operationID: Int) -> Bool {
        state.withLock { state in
            !state.disposed && operationID == state.currentID
        }
    }

    func dispose() {
        state.withLock { state in
            state.disposed = true
            state.currentID += 1
        }
    }
}
