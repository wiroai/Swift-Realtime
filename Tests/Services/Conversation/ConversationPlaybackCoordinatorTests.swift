import XCTest
@testable import SwiftRealtime

final class ConversationPlaybackCoordinatorTests: XCTestCase {
    private var player: AlwaysAcceptPlayer!
    private var coordinator: ConversationPlaybackCoordinator!

    override func setUp() {
        super.setUp()
        player = AlwaysAcceptPlayer()
        coordinator = ConversationPlaybackCoordinator(player)
    }

    func testAudioInsideOneTurnReachesThePlayerUntouched() {
        let first = coordinator.enqueue(chunk(1))
        let second = coordinator.enqueue(chunk(2))

        XCTAssertEqual(player.flushes, 0)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(2)])
        XCTAssertFalse(first.flushedPreviousTurn)
        XCTAssertFalse(second.flushedPreviousTurn)
    }

    func testTheFirstChunkOfANewTurnClearsTheInterruptedTail() {
        _ = coordinator.enqueue(chunk(1))
        coordinator.markTurnFinished()

        let outcome = coordinator.enqueue(chunk(2))

        XCTAssertTrue(outcome.flushedPreviousTurn)
        XCTAssertEqual(player.flushes, 1)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(2)])
    }

    func testOnlyTheFirstChunkOfANewTurnFlushes() {
        coordinator.markTurnFinished()

        _ = coordinator.enqueue(chunk(1))
        let second = coordinator.enqueue(chunk(2))

        XCTAssertEqual(player.flushes, 1)
        XCTAssertFalse(second.flushedPreviousTurn)
    }

    func testAFullQueueIsReportedAsADroppedChunk() {
        player.accepts = false

        let outcome = coordinator.enqueue(chunk(1))

        XCTAssertTrue(outcome.droppedChunk)
        XCTAssertFalse(outcome.flushedPreviousTurn)
    }

    func testAFlushAndADropAreReportedTogether() {
        coordinator.markTurnFinished()
        player.accepts = false

        let outcome = coordinator.enqueue(chunk(1))

        XCTAssertTrue(outcome.flushedPreviousTurn)
        XCTAssertTrue(outcome.droppedChunk)
        XCTAssertEqual(player.flushes, 1)
    }

    func testResetDropsThePendingTurnSoANewSessionNeverFlushes() {
        coordinator.markTurnFinished()
        coordinator.reset()

        let outcome = coordinator.enqueue(chunk(1))

        XCTAssertFalse(outcome.flushedPreviousTurn)
        XCTAssertEqual(player.flushes, 0)
    }

    func testInterruptingFlushesOnceAndSilencesTheRestOfTheTurn() {
        _ = coordinator.enqueue(chunk(1))

        XCTAssertTrue(coordinator.interruptTurn())
        XCTAssertFalse(coordinator.interruptTurn())

        let silenced = coordinator.enqueue(chunk(2))

        XCTAssertEqual(player.flushes, 1)
        XCTAssertTrue(silenced.silencedChunk)
        XCTAssertEqual(player.enqueued, [chunk(1)])
    }

    func testTheTurnAfterAnInterruptionStartsOnAFlushedPlayer() {
        // The cut turn's flush ran while its audio was still in
        // flight; the next turn must not queue behind a straggler
        // that landed after it.
        _ = coordinator.enqueue(chunk(1))
        _ = coordinator.interruptTurn()
        _ = coordinator.enqueue(chunk(2))
        coordinator.markTurnFinished()

        let outcome = coordinator.enqueue(chunk(3))

        XCTAssertFalse(outcome.silencedChunk)
        XCTAssertTrue(outcome.flushedPreviousTurn)
        XCTAssertEqual(player.flushes, 2)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(3)])
    }

    func testReleasingAnInterruptedTurnLetsTheNextAnswerPlay() {
        _ = coordinator.enqueue(chunk(1))
        _ = coordinator.interruptTurn()
        _ = coordinator.enqueue(chunk(2))

        XCTAssertTrue(coordinator.releaseInterruptedTurn())
        XCTAssertFalse(coordinator.releaseInterruptedTurn())

        let outcome = coordinator.enqueue(chunk(3))

        XCTAssertFalse(outcome.silencedChunk)
        XCTAssertTrue(outcome.flushedPreviousTurn)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(3)])
    }

    func testReleasingWithoutAnInterruptionChangesNothing() {
        _ = coordinator.enqueue(chunk(1))

        XCTAssertFalse(coordinator.releaseInterruptedTurn())

        let outcome = coordinator.enqueue(chunk(2))

        XCTAssertFalse(outcome.flushedPreviousTurn)
        XCTAssertEqual(player.flushes, 0)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(2)])
    }

    func testAStreamEndAfterAReleaseIsAnOrdinaryTurnBoundary() {
        _ = coordinator.enqueue(chunk(1))
        _ = coordinator.interruptTurn()
        _ = coordinator.releaseInterruptedTurn()
        _ = coordinator.enqueue(chunk(2))
        coordinator.markTurnFinished()

        let outcome = coordinator.enqueue(chunk(3))

        XCTAssertFalse(outcome.silencedChunk)
        XCTAssertTrue(outcome.flushedPreviousTurn)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(2), chunk(3)])
    }

    func testInterruptingAFinishedTailStillLatches() {
        // `task_stream_end` can arrive well before the network has
        // delivered every chunk of that turn's own audio, so a tail
        // still queued when the user interrupts is not proof nothing
        // more is coming — silencing it is the safe assumption.
        _ = coordinator.enqueue(chunk(1))
        coordinator.markTurnFinished()

        XCTAssertTrue(coordinator.interruptTurn())

        let stillSameTurn = coordinator.enqueue(chunk(2))

        XCTAssertTrue(stillSameTurn.silencedChunk)
        XCTAssertFalse(stillSameTurn.flushedPreviousTurn)
        XCTAssertEqual(player.flushes, 1)
        XCTAssertEqual(player.enqueued, [chunk(1)])

        coordinator.markTurnFinished()
        let nextTurn = coordinator.enqueue(chunk(3))

        XCTAssertFalse(nextTurn.silencedChunk)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(3)])
    }

    func testAnInterruptedTurnKeepsSilencingALongAnswer() {
        // A story-length turn can run far longer than any short
        // network hiccup; silencing must survive minutes of it, not
        // just a couple of seconds.
        var now = Date()
        coordinator.clock = { now }

        _ = coordinator.enqueue(chunk(1))
        coordinator.markTurnFinished()
        _ = coordinator.interruptTurn()

        now = now.addingTimeInterval(45)
        let stillSilenced = coordinator.enqueue(chunk(2))
        XCTAssertTrue(stillSilenced.silencedChunk)
        XCTAssertEqual(player.enqueued, [chunk(1)])
    }

    func testTheLatchTimeoutStopsSilencingAStuckStream() {
        var now = Date()
        coordinator.clock = { now }

        _ = coordinator.enqueue(chunk(1))
        coordinator.markTurnFinished()
        _ = coordinator.interruptTurn()

        now = now.addingTimeInterval(91)
        let pastTimeout = coordinator.enqueue(chunk(3))
        XCTAssertFalse(pastTimeout.silencedChunk)
        XCTAssertEqual(player.enqueued, [chunk(1), chunk(3)])
    }

    func testAHoldDucksThePlayerAndLeavesTheTurnPlaying() {
        _ = coordinator.enqueue(secondLong(1))

        XCTAssertTrue(coordinator.holdTurn())
        XCTAssertTrue(coordinator.isHolding)
        XCTAssertTrue(player.ducked)
        XCTAssertEqual(player.flushes, 0)
        XCTAssertEqual(player.enqueued, [secondLong(1)])

        XCTAssertTrue(coordinator.resumeHeldTurn())

        XCTAssertFalse(coordinator.isHolding)
        XCTAssertFalse(player.ducked)
        XCTAssertFalse(coordinator.resumeHeldTurn())
    }

    func testChunksArrivingDuringAHoldKeepPlayingDucked() {
        _ = coordinator.enqueue(secondLong(1))
        _ = coordinator.holdTurn()

        let outcome = coordinator.enqueue(secondLong(2))

        XCTAssertFalse(outcome.droppedChunk)
        XCTAssertFalse(outcome.flushedPreviousTurn)
        XCTAssertTrue(player.ducked)
        XCTAssertEqual(player.enqueued, [secondLong(1), secondLong(2)])
    }

    func testCommittingAHeldTurnDiscardsItsAudioAndLatches() {
        _ = coordinator.enqueue(secondLong(1))
        _ = coordinator.holdTurn()

        XCTAssertTrue(coordinator.interruptTurn())

        XCTAssertFalse(coordinator.isHolding)
        XCTAssertFalse(player.ducked)
        XCTAssertEqual(player.flushes, 1)
        XCTAssertFalse(coordinator.resumeHeldTurn())

        let silenced = coordinator.enqueue(secondLong(2))

        XCTAssertTrue(silenced.silencedChunk)
        XCTAssertEqual(player.enqueued.count, 1)
    }

    func testHoldingWithNothingUnplayedIsRefused() {
        XCTAssertFalse(coordinator.holdTurn())
        XCTAssertFalse(player.ducked)

        _ = coordinator.enqueue(secondLong(1))
        _ = coordinator.interruptTurn()

        XCTAssertFalse(coordinator.holdTurn())
        XCTAssertFalse(player.ducked)
    }

    func testAHoldNeverStacks() {
        _ = coordinator.enqueue(secondLong(1))

        XCTAssertTrue(coordinator.holdTurn())
        XCTAssertFalse(coordinator.holdTurn())
        XCTAssertEqual(player.duckChanges, 1)
    }

    func testATurnBoundaryDuringAHoldStillClearsTheTail() {
        _ = coordinator.enqueue(secondLong(1))
        _ = coordinator.holdTurn()
        coordinator.markTurnFinished()

        let outcome = coordinator.enqueue(secondLong(2))

        XCTAssertTrue(outcome.flushedPreviousTurn)
        XCTAssertTrue(coordinator.isHolding)
        XCTAssertTrue(player.ducked)
        XCTAssertEqual(player.enqueued.last, secondLong(2))
    }

    func testResetClearsAHoldAndBringsTheSpeakerBack() {
        _ = coordinator.enqueue(secondLong(1))
        _ = coordinator.holdTurn()
        coordinator.reset()

        XCTAssertFalse(coordinator.isHolding)
        XCTAssertFalse(player.ducked)
        XCTAssertFalse(coordinator.resumeHeldTurn())
    }
}

private func chunk(_ seed: UInt8) -> Data {
    Data([seed, seed])
}

private func secondLong(_ seed: UInt8) -> Data {
    Data(repeating: seed, count: 48_000)
}

final class AlwaysAcceptPlayer: PcmAudioPlayer, @unchecked Sendable {
    var accepts = true
    var flushes = 0
    var ducked = false
    var duckChanges = 0
    var enqueued: [Data] = []

    var isPlaying: Bool { true }
    var isEnabled: Bool { true }
    var failures: AsyncStream<AudioFailure> {
        AsyncStream { $0.finish() }
    }

    func tryEnqueue(_ chunk: Data) -> Bool {
        if !accepts {
            return false
        }
        enqueued.append(chunk)
        return true
    }

    func flush() {
        flushes += 1
    }

    func setDucked(_ ducked: Bool) {
        if self.ducked != ducked {
            duckChanges += 1
        }
        self.ducked = ducked
    }

    func start() async throws {}
    func enqueue(_: Data) async {}
    func complete() async {}
    func setEnabled(_: Bool) async {}
    func stop() async {}
    func dispose() async {}
}
