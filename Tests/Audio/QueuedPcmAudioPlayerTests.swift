import XCTest
@testable import SwiftRealtime

final class QueuedPcmAudioPlayerTests: XCTestCase {
    func testAudioFailuresExposeStableCodes() {
        XCTAssertEqual(
            AudioFailure.playback.code,
            .playbackUnavailable,
        )
        XCTAssertEqual(
            AudioFailure.capture.code,
            .captureUnavailable,
        )
    }

    func testFeedsQueuedChunksToTheSinkInFIFOOrder() async throws {
        let sink = FakePcmPlaybackSink()
        let player = QueuedPcmAudioPlayer(sink)

        try await player.start()
        await player.enqueue(Data([1]))
        await player.enqueue(Data([2]))
        await player.complete()

        XCTAssertEqual(sink.fedChunks, [Data([1]), Data([2])])
        XCTAssertEqual(sink.endOfStreamCalls, 1)
        XCTAssertFalse(player.isPlaying)
        await player.dispose()
    }

    func testCompletionWaitsOutALongTailWhileSinkConsumes() async throws {
        let sink = FakePcmPlaybackSink(feedDelay: .milliseconds(30))
        let player = QueuedPcmAudioPlayer(
            sink,
            drainTimeout: .milliseconds(60),
        )

        try await player.start()
        for index in 0..<10 {
            await player.enqueue(Data([UInt8(index)]))
        }
        await player.complete()

        XCTAssertEqual(sink.fedChunks.count, 10)
        XCTAssertEqual(sink.endOfStreamCalls, 1)
        XCTAssertFalse(player.isPlaying)
        await player.dispose()
    }

    func testAStalledSinkStillLetsCompletionFinish() async throws {
        let sink = FakePcmPlaybackSink(stalled: true)
        let player = QueuedPcmAudioPlayer(
            sink,
            drainTimeout: .milliseconds(40),
        )

        try await player.start()
        await player.enqueue(Data([1]))

        await player.complete()

        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(sink.fedChunks.isEmpty)
        await player.dispose()
    }

    func testAChunkEnqueuedRightAfterAFlushSurvivesTheSinkReset()
        async throws
    {
        let sink = FakePcmPlaybackSink()
        let player = QueuedPcmAudioPlayer(sink)

        try await player.start()
        await player.enqueue(Data([1]))
        player.flush()
        await player.enqueue(Data([2]))
        await player.complete()

        XCTAssertEqual(sink.fedChunks, [Data([2])])
        await player.dispose()
    }

    func testAFlushDuringAnInFlightFeedRemovesThatChunkToo()
        async throws
    {
        // The chunk was past the generation check when the flush
        // landed, so the sink may have been reset before it arrived.
        let sink = FakePcmPlaybackSink(feedDelay: .milliseconds(40))
        let player = QueuedPcmAudioPlayer(sink)

        try await player.start()
        await player.enqueue(Data([1]))
        try await Task.sleep(for: .milliseconds(10))
        player.flush()
        await player.enqueue(Data([2]))
        await player.complete()

        XCTAssertEqual(sink.fedChunks, [Data([2])])
        await player.dispose()
    }

    func testSpeakerDisableFlushesAndReenableAcceptsPCM() async throws {
        let sink = FakePcmPlaybackSink()
        let player = QueuedPcmAudioPlayer(sink)

        try await player.start()
        await player.setEnabled(false)
        await player.enqueue(Data([1, 2]))
        await player.setEnabled(true)
        await player.enqueue(Data([3, 4]))
        await player.complete()

        XCTAssertEqual(sink.fedChunks, [Data([3, 4])])
        XCTAssertEqual(sink.volumes, [1, 0, 1])
        XCTAssertEqual(sink.stopCalls, 1)
        XCTAssertTrue(player.isEnabled)
        await player.dispose()
    }

    func testReportsSanitizedPlaybackFailures() async throws {
        let sink = FakePcmPlaybackSink(failFeed: true)
        let player = QueuedPcmAudioPlayer(sink)
        let failureTask = Task { () -> AudioFailure? in
            for await failure in player.failures {
                return failure
            }
            return nil
        }

        try await player.start()
        await player.enqueue(Data([1]))

        let failure = await failureTask.value
        XCTAssertEqual(failure, .playback)
        XCTAssertFalse(
            String(describing: failure).contains("platform"),
        )
        await player.dispose()
    }

    func testEveryStartReinitializesTheSinkAndDisposeRunsOnce()
        async throws
    {
        let sink = FakePcmPlaybackSink()
        let player = QueuedPcmAudioPlayer(sink)

        try await player.start()
        await player.stop()
        try await player.start()
        await player.complete()
        await player.dispose()
        await player.dispose()

        XCTAssertEqual(sink.initializeCalls, 2)
        XCTAssertEqual(sink.playCalls, 2)
        XCTAssertEqual(sink.disposeCalls, 1)
    }
}
