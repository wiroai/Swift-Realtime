import Foundation
import os

/// Bounded FIFO of PCM chunks with overflow shed and backpressure.
///
/// `tryAdd` never waits — a full queue refuses the chunk and says so.
/// `add` waits for space so a slower consumer can catch up. `take`
/// waits for data or a close. Close releases every waiter.
final class BoundedPcmQueue: @unchecked Sendable {
    /// What a parked `take` wakes up to. A producer never hands a
    /// chunk to the waiter directly: it stores the chunk and wakes the
    /// waiter to dequeue it under the lock, so a `clear` that lands in
    /// between still removes it. A chunk in flight to a consumer that
    /// has not run yet would otherwise outlive the flush meant to
    /// discard it.
    private enum Wake {
        case chunk(TakenChunk)
        case finished
        case retry
    }

    /// A dequeued chunk with the `clearCount` it was dequeued under.
    /// A consumer that compares it against the current count after
    /// its own bookkeeping can tell a chunk that a `clear` meant to
    /// discard from one queued after that `clear`.
    struct TakenChunk {
        let bytes: Data
        let clearCount: Int
    }

    private final class DataWaiter: @unchecked Sendable {
        private var continuation: CheckedContinuation<Wake, Never>?

        init(_ continuation: CheckedContinuation<Wake, Never>) {
            self.continuation = continuation
        }

        func complete(_ value: Wake) -> Bool {
            guard let continuation else {
                return false
            }
            self.continuation = nil
            continuation.resume(returning: value)
            return true
        }
    }

    private final class SpaceWaiter: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func complete() -> Bool {
            guard let continuation else {
                return false
            }
            self.continuation = nil
            continuation.resume()
            return true
        }
    }

    private struct State {
        var chunks: [Data] = []
        var dataWaiters: [DataWaiter] = []
        var spaceWaiters: [SpaceWaiter] = []
        var closed = false
        var clearCount = 0
    }

    private enum AddAttempt {
        case added
        case closed
        case full
    }

    private enum TakeAttempt {
        case chunk(TakenChunk)
        case finished
        case waiting
    }

    let capacityInChunks: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacityInChunks: Int) {
        precondition(
            capacityInChunks > 0,
            "Queue capacity must be positive.",
        )
        self.capacityInChunks = capacityInChunks
    }

    var length: Int {
        state.withLock(\.chunks.count)
    }

    var isClosed: Bool {
        state.withLock(\.closed)
    }

    /// Number of `clear` calls so far; see `TakenChunk`.
    var clearCount: Int {
        state.withLock(\.clearCount)
    }

    func tryAdd(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else {
            return true
        }
        let pair = state.withLock { state -> (Bool, DataWaiter?) in
            if state.closed || state.chunks.count >= capacityInChunks {
                return (false, nil)
            }
            return (true, enqueue(chunk, on: &state))
        }
        if let waiter = pair.1 {
            _ = waiter.complete(.retry)
        }
        return pair.0
    }

    func add(_ chunk: Data) async {
        guard !chunk.isEmpty else {
            return
        }
        while true {
            let pair = state.withLock { state -> (AddAttempt, DataWaiter?) in
                if state.closed {
                    return (.closed, nil)
                }
                if state.chunks.count < capacityInChunks {
                    return (.added, enqueue(chunk, on: &state))
                }
                return (.full, nil)
            }
            if let waiter = pair.1 {
                _ = waiter.complete(.retry)
            }
            switch pair.0 {
            case .added, .closed:
                return
            case .full:
                let stillOpen = await parkForSpace()
                if !stillOpen {
                    return
                }
            }
        }
    }

    func take() async -> Data? {
        await takeStamped()?.bytes
    }

    func takeStamped() async -> TakenChunk? {
        while true {
            switch await awaitChunk() {
            case let .chunk(chunk):
                return chunk
            case .finished:
                return nil
            case .retry:
                continue
            }
        }
    }

    private func awaitChunk() async -> Wake {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiter = DataWaiter(continuation)
                let pair = state.withLock {
                    state -> (TakeAttempt, [SpaceWaiter]) in
                    if !state.chunks.isEmpty {
                        return dequeue(from: &state)
                    }
                    if state.closed {
                        return (.finished, [])
                    }
                    state.dataWaiters.append(waiter)
                    return (.waiting, [])
                }
                // dequeue already extracted space waiters into the
                // attempt payload so they resume outside the lock.
                switch pair.0 {
                case let .chunk(chunk):
                    for spaceWaiter in pair.1 {
                        _ = spaceWaiter.complete()
                    }
                    _ = waiter.complete(.chunk(chunk))
                case .finished:
                    _ = waiter.complete(.finished)
                case .waiting:
                    break
                }
            }
        } onCancel: {
            resumeCancelledTake()
        }
    }

    func chunks() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    guard let chunk = await self.take() else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func clear() {
        let waiters = state.withLock { state -> [SpaceWaiter] in
            state.chunks.removeAll()
            state.clearCount += 1
            let waiters = state.spaceWaiters
            state.spaceWaiters = []
            return waiters
        }
        for waiter in waiters {
            _ = waiter.complete()
        }
    }

    func close() {
        let pair: ([DataWaiter], [SpaceWaiter]) = state.withLock { state in
            if state.closed {
                return ([], [])
            }
            state.closed = true
            let data = state.dataWaiters
            let space = state.spaceWaiters
            state.dataWaiters = []
            state.spaceWaiters = []
            return (data, space)
        }
        for waiter in pair.0 {
            _ = waiter.complete(.finished)
        }
        for waiter in pair.1 {
            _ = waiter.complete()
        }
    }

    /// Stores the chunk and returns the consumer to wake, if one is
    /// parked. The waiter is resumed outside the lock.
    private func enqueue(
        _ chunk: Data,
        on state: inout State,
    ) -> DataWaiter? {
        state.chunks.append(Data(chunk))
        if state.dataWaiters.isEmpty {
            return nil
        }
        return state.dataWaiters.removeFirst()
    }

    private func dequeue(
        from state: inout State,
    ) -> (TakeAttempt, [SpaceWaiter]) {
        let chunk = TakenChunk(
            bytes: state.chunks.removeFirst(),
            clearCount: state.clearCount,
        )
        let waiters = state.spaceWaiters
        state.spaceWaiters = []
        return (.chunk(chunk), waiters)
    }

    private func parkForSpace() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiter = SpaceWaiter(continuation)
                let shouldWait = state.withLock { state -> Bool in
                    if state.closed {
                        return false
                    }
                    if state.chunks.count < capacityInChunks {
                        return false
                    }
                    state.spaceWaiters.append(waiter)
                    return true
                }
                if !shouldWait {
                    _ = waiter.complete()
                }
            }
            return !state.withLock(\.closed)
        } onCancel: {
            resumeCancelledSpace()
        }
    }

    private func resumeCancelledTake() {
        let waiter = state.withLock { state -> DataWaiter? in
            guard !state.dataWaiters.isEmpty else {
                return nil
            }
            return state.dataWaiters.removeLast()
        }
        _ = waiter?.complete(.finished)
    }

    private func resumeCancelledSpace() {
        let waiter = state.withLock { state -> SpaceWaiter? in
            guard !state.spaceWaiters.isEmpty else {
                return nil
            }
            return state.spaceWaiters.removeLast()
        }
        _ = waiter?.complete()
    }
}
