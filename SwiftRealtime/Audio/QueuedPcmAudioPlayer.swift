import Foundation
import os

/// Plays PCM through a sink, with a bounded queue in front.
///
/// `complete` waits out the queued tail for as long as the sink keeps
/// consuming. A sink that stopped draining — a torn-down engine, a
/// task the server just ended — must not hold the caller forever.
final class QueuedPcmAudioPlayer: PcmAudioPlayer, @unchecked Sendable {
    private struct State {
        var queue: BoundedPcmQueue?
        var consumeTask: Task<Void, Never>?
        var playing = false
        var enabled = true
        var initialized = false
        var disposed = false
        var playbackGeneration = 0
        var pendingFlush: Task<Void, Never>?
        var flushCount = 0
        var consumedChunks = 0
        var consumeFinished = false
    }

    /// What the queue-facing entry points need to know, read in one
    /// go so an `enabled` toggle cannot land between the fields.
    private struct EnqueueSnapshot {
        let playing: Bool
        let enabled: Bool
        let queue: BoundedPcmQueue?
    }

    private let sink: any PcmPlaybackSink
    private let queueCapacityInChunks: Int
    private let maxNativeBufferDuration: Duration
    private let backpressurePollInterval: Duration
    private let drainTimeout: Duration
    private let failureStream: AsyncStream<AudioFailure>
    private let failureContinuation:
        AsyncStream<AudioFailure>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        _ sink: any PcmPlaybackSink,
        queueCapacityInChunks: Int =
            AudioConstants.defaultQueueCapacityInChunks,
        maxNativeBufferDuration: Duration = .seconds(2),
        backpressurePollInterval: Duration = .milliseconds(10),
        drainTimeout: Duration = .seconds(5),
    ) {
        self.sink = sink
        self.queueCapacityInChunks = queueCapacityInChunks
        self.maxNativeBufferDuration = maxNativeBufferDuration
        self.backpressurePollInterval = backpressurePollInterval
        self.drainTimeout = drainTimeout
        let pair = AsyncStream<AudioFailure>.makeStream()
        failureStream = pair.stream
        failureContinuation = pair.continuation
    }

    var isPlaying: Bool {
        state.withLock(\.playing)
    }

    var isEnabled: Bool {
        state.withLock(\.enabled)
    }

    var failures: AsyncStream<AudioFailure> {
        failureStream
    }

    func start() async throws {
        let (disposed, playing) = state.withLock {
            ($0.disposed, $0.playing)
        }
        if disposed {
            throw AudioFailure.playback
        }
        if playing {
            return
        }
        do {
            try await sink.initialize()
            let queue = BoundedPcmQueue(
                capacityInChunks: queueCapacityInChunks,
            )
            let enabled = state.withLock { state -> Bool in
                state.initialized = true
                state.queue = queue
                state.playing = true
                state.consumeFinished = false
                state.playbackGeneration += 1
                return state.enabled
            }
            try await sink.setVolume(enabled ? 1 : 0)
            try await sink.play()
            let task = Task { [weak self] in
                guard let self else {
                    return
                }
                await self.consume(queue)
            }
            state.withLock { $0.consumeTask = task }
        } catch {
            let queue = state.withLock { state -> BoundedPcmQueue? in
                state.playing = false
                return state.queue
            }
            queue?.close()
            throw AudioFailure.playback
        }
    }

    func tryEnqueue(_ chunk: Data) -> Bool {
        let snapshot = enqueueSnapshot()
        guard snapshot.playing, !chunk.isEmpty else {
            return false
        }
        if !snapshot.enabled {
            return true
        }
        return snapshot.queue?.tryAdd(chunk) ?? false
    }

    func enqueue(_ chunk: Data) async {
        let snapshot = enqueueSnapshot()
        guard snapshot.playing, snapshot.enabled, !chunk.isEmpty else {
            return
        }
        await snapshot.queue?.add(chunk)
    }

    /// Synchronous so a barge-in can call it from the capture thread.
    /// The sink is reset on a task, and the consumer waits for that
    /// task before its next feed: the chunk the caller enqueues right
    /// after a flush must land behind the reset, not be wiped by it.
    func flush() {
        guard state.withLock(\.playing) else {
            return
        }
        // Cleared before the generation moves: the consumer reads the
        // generation first and the queue's clear count second, so a
        // flush must be visible in the queue no later than in the
        // generation for one of those two checks to catch it.
        state.withLock(\.queue)?.clear()
        state.withLock { state in
            state.playbackGeneration += 1
            state.flushCount += 1
            // Spawned under the lock so the count is already bumped by
            // the time the reset can run; the consumer compares that
            // count around its feed to catch a reset that raced it.
            state.pendingFlush = Task<Void, Never> { [weak self] in
                await self?.flushSink()
            }
        }
    }

    func complete() async {
        let (playing, queue, worker) = state.withLock {
            ($0.playing, $0.queue, $0.consumeTask)
        }
        guard playing else {
            return
        }
        queue?.close()
        do {
            if worker != nil {
                try await drainWhileProgressing()
            }
            let drained = state.withLock { state in
                (
                    playing: state.playing,
                    disposed: state.disposed,
                    enabled: state.enabled,
                )
            }
            if !drained.playing || drained.disposed {
                return
            }
            if drained.enabled {
                await withTimeout(drainTimeout) {
                    try? await self.sink.endOfStream()
                }
            }
            state.withLock { state in
                state.playing = false
                state.queue = nil
                state.consumeTask = nil
            }
        } catch {
            abandonTail()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        let (changed, initialized) = state.withLock {
            state -> (Bool, Bool) in
            if state.enabled == enabled {
                return (false, state.initialized)
            }
            state.enabled = enabled
            state.playbackGeneration += 1
            if !enabled {
                state.queue?.clear()
            }
            return (true, state.initialized)
        }
        guard changed, initialized else {
            return
        }
        do {
            if enabled {
                try await sink.setVolume(1)
                if state.withLock(\.playing) {
                    try await sink.play()
                }
            } else {
                try await sink.setVolume(0)
                try await sink.stop()
            }
        } catch {
            reportFailure()
        }
    }

    func stop() async {
        let hasConsumer = state.withLock { state -> Bool in
            state.playing = false
            state.playbackGeneration += 1
            state.queue?.clear()
            state.queue?.close()
            return state.consumeTask != nil
        }
        if hasConsumer {
            await waitUntilFinishedOrTimeout(drainTimeout)
        }
        let initialized = state.withLock { state -> Bool in
            state.queue = nil
            state.consumeTask = nil
            return state.initialized
        }
        if initialized {
            do {
                try await sink.stop()
            } catch {
                reportFailure()
            }
        }
    }

    func dispose() async {
        let alreadyDisposed = state.withLock { state -> Bool in
            if state.disposed {
                return true
            }
            state.disposed = true
            return false
        }
        if alreadyDisposed {
            return
        }
        await stop()
        if state.withLock(\.initialized) {
            await sink.dispose()
        }
        failureContinuation.finish()
    }

    private func enqueueSnapshot() -> EnqueueSnapshot {
        state.withLock { state in
            EnqueueSnapshot(
                playing: state.playing,
                enabled: state.enabled,
                queue: state.queue,
            )
        }
    }

    private func consume(_ queue: BoundedPcmQueue) async {
        defer {
            state.withLock { $0.consumeFinished = true }
        }
        do {
            // Taken one at a time rather than through `chunks()`: that
            // stream reads ahead into its own buffer, and a chunk
            // parked there outlives `clear()`, so every flush during
            // playback would let one chunk of the cut turn through.
            while let taken = await queue.takeStamped() {
                let before = state.withLock { state in
                    (
                        playing: state.playing,
                        enabled: state.enabled,
                        generation: state.playbackGeneration,
                        flushes: state.flushCount,
                    )
                }
                if !before.playing {
                    return
                }
                if !before.enabled {
                    continue
                }
                // Read after the generation so a flush that slipped in
                // between dequeue and that read shows up in one of the
                // two: here as a stale stamp, or below as a generation
                // that moved on.
                if taken.clearCount != queue.clearCount {
                    continue
                }
                let chunk = taken.bytes
                await waitForNativeCapacity()
                await state.withLock(\.pendingFlush)?.value
                let armed = state.withLock { state in
                    (
                        playing: state.playing,
                        enabled: state.enabled,
                        generation: state.playbackGeneration,
                    )
                }
                if !armed.playing {
                    return
                }
                if !armed.enabled
                    || before.generation != armed.generation
                {
                    continue
                }
                try await sink.feed(chunk)
                let after = state.withLock { state in
                    state.consumedChunks += 1
                    return (
                        playing: state.playing,
                        flushes: state.flushCount,
                    )
                }
                // A flush that landed while this chunk was on its way
                // into the sink may have reset the sink before the
                // chunk arrived, leaving a fragment of the cut turn
                // scheduled behind the reset. Nothing newer has been
                // fed yet — this loop is the only feeder — so resetting
                // once more removes only that fragment.
                if before.flushes != after.flushes, after.playing {
                    try await sink.flush()
                }
            }
        } catch {
            reportFailure()
        }
    }

    private func drainWhileProgressing() async throws {
        var lastConsumed = state.withLock(\.consumedChunks)
        var idle = ContinuousClock.now
        while true {
            let (finished, consumed) = state.withLock {
                ($0.consumeFinished, $0.consumedChunks)
            }
            if finished {
                return
            }
            if consumed != lastConsumed {
                lastConsumed = consumed
                idle = .now
            } else if ContinuousClock.now - idle >= drainTimeout {
                throw AudioFailure.playback
            }
            try await Task.sleep(for: backpressurePollInterval)
        }
    }

    private func waitForNativeCapacity() async {
        while state.withLock(\.playing) {
            let buffered = await sink.bufferedDuration()
            if buffered < maxNativeBufferDuration {
                return
            }
            try? await Task.sleep(for: backpressurePollInterval)
        }
    }

    private func abandonTail() {
        state.withLock { state in
            state.playing = false
            state.queue?.clear()
            state.queue?.close()
            state.queue = nil
            state.consumeTask = nil
        }
        Task { [weak self] in
            await self?.stopAfterFailure()
        }
    }

    private func flushSink() async {
        guard state.withLock(\.initialized) else {
            return
        }
        do {
            try await sink.flush()
        } catch {
            reportFailure()
        }
    }

    private func reportFailure() {
        state.withLock { state in
            state.playing = false
            state.queue?.clear()
            state.queue?.close()
        }
        failureContinuation.yield(.playback)
        Task { [weak self] in
            await self?.stopAfterFailure()
        }
    }

    private func stopAfterFailure() async {
        guard state.withLock(\.initialized) else {
            return
        }
        try? await sink.stop()
    }

    private func withTimeout(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async -> Void,
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func waitUntilFinishedOrTimeout(_ timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if state.withLock(\.consumeFinished) {
                return
            }
            try? await Task.sleep(for: backpressurePollInterval)
        }
        state.withLock { $0.playing = false }
    }
}
