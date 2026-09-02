import Foundation
import os

/// Chunks a capture source into 20 ms PCM frames behind a bounded queue.
final class BufferedPcmAudioRecorder: PcmAudioRecorder, @unchecked Sendable {
    private struct State: Sendable {
        var queue: BoundedPcmQueue?
        var chunker: PcmChunker?
        var sourceTask: Task<Void, Never>?
        var captureFailure: AudioFailure?
        var recording = false
        var muted = false
        var disposed = false
        var captureGeneration = 0
        var mutedSourceBuffers = 0
        var outputStream: AsyncThrowingStream<Data, Error>?
    }

    private let source: any PcmCaptureSource
    private let queueCapacityInChunks: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        _ source: any PcmCaptureSource,
        queueCapacityInChunks: Int =
            AudioConstants.defaultQueueCapacityInChunks,
    ) {
        self.source = source
        self.queueCapacityInChunks = queueCapacityInChunks
    }

    var isRecording: Bool {
        state.withLock(\.recording)
    }

    var isMuted: Bool {
        state.withLock(\.muted)
    }

    /// Source buffers discarded because the microphone was muted when
    /// they were processed. Mute is decided at processing time, not at
    /// capture time, so this is the only way to observe that a buffer
    /// captured under mute has already been dropped.
    var mutedSourceBuffers: Int {
        state.withLock(\.mutedSourceBuffers)
    }

    func start(
        _ profile: PcmCaptureProfile,
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let existing = state.withLock { state in
            (
                disposed: state.disposed,
                recording: state.recording,
                stream: state.outputStream,
            )
        }
        if existing.disposed {
            throw AudioFailure.capture
        }
        if let stream = existing.stream, existing.recording {
            return stream
        }

        let queue = BoundedPcmQueue(
            capacityInChunks: queueCapacityInChunks,
        )
        let chunker = PcmChunker(
            chunkSizeInBytes: AudioConstants.pcmBytesPerChunk,
        )
        state.withLock { state in
            state.queue = queue
            state.chunker = chunker
            state.captureFailure = nil
            state.captureGeneration += 1
        }

        let sourceStream: AsyncThrowingStream<Data, Error>
        do {
            sourceStream = try await source.start(profile)
        } catch {
            queue.close()
            throw AudioFailure.capture
        }

        let output = makeOutputStream(queue)
        state.withLock { state in
            state.recording = true
            state.outputStream = output
            state.sourceTask = Task { [weak self] in
                await self?.pump(sourceStream)
            }
        }
        return output
    }

    func setMuted(_ muted: Bool) {
        state.withLock { state in
            state.muted = muted
            if muted {
                state.captureGeneration += 1
                state.queue?.clear()
                state.chunker?.reset()
            }
        }
    }

    func stop() async {
        let sourceTask = state.withLock { state in
            state.recording = false
            state.captureGeneration += 1
            return state.sourceTask
        }
        sourceTask?.cancel()
        if let sourceTask {
            await sourceTask.value
        }
        state.withLock { state in
            state.sourceTask = nil
            state.queue?.clear()
            state.queue?.close()
            state.chunker?.reset()
            state.outputStream = nil
        }
        await source.stop()
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
        await source.dispose()
    }

    private func pump(
        _ sourceStream: AsyncThrowingStream<Data, Error>,
    ) async {
        do {
            for try await bytes in sourceStream {
                if Task.isCancelled {
                    return
                }
                await handleSourceData(bytes)
            }
            state.withLock { state in
                state.recording = false
                state.queue?.close()
            }
        } catch {
            state.withLock { state in
                state.captureFailure = .capture
                state.recording = false
                state.queue?.close()
            }
            await source.stop()
        }
    }

    private func handleSourceData(_ bytes: Data) async {
        let snapshot = state.withLock { state in
            (
                recording: state.recording,
                muted: state.muted,
                generation: state.captureGeneration,
                queue: state.queue,
                chunker: state.chunker,
            )
        }
        guard snapshot.recording else {
            return
        }
        if snapshot.muted {
            state.withLock { $0.mutedSourceBuffers += 1 }
            return
        }
        guard let queue = snapshot.queue, let chunker = snapshot.chunker
        else {
            return
        }
        for chunk in chunker.add(bytes) {
            guard isCurrent(snapshot.generation) else {
                return
            }
            await queue.add(chunk)
            if !isCurrent(snapshot.generation) {
                queue.clear()
                return
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { state in
            state.recording
                && !state.muted
                && generation == state.captureGeneration
        }
    }

    private func makeOutputStream(
        _ queue: BoundedPcmQueue,
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await chunk in queue.chunks() {
                    continuation.yield(chunk)
                }
                if let failure = self.state.withLock(\.captureFailure) {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
