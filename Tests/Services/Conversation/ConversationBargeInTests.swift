import os
import XCTest
@testable import SwiftRealtime

final class ConversationBargeInTests: XCTestCase {
    private var player: AlwaysAcceptPlayer!
    private var playback: ConversationPlaybackCoordinator!
    private var voiceActivity: ConversationVoiceActivity!
    private var protocolEvents: OSAllocatedUnfairLock<[String]>!
    private var clock: TestClock!
    private var bargeIn: ConversationBargeIn!

    override func setUp() {
        super.setUp()
        clock = TestClock()
        player = AlwaysAcceptPlayer()
        playback = ConversationPlaybackCoordinator(player)
        voiceActivity = ConversationVoiceActivity()
        protocolEvents = OSAllocatedUnfairLock(initialState: [])
        let events = protocolEvents!
        bargeIn = ConversationBargeIn(
            playback: playback,
            voiceActivity: voiceActivity,
            onProtocolEvent: { event in
                events.withLock { $0.append(event) }
            },
            holdTimeout: .milliseconds(900),
            holdCooldown: .milliseconds(1_500),
            clock: clock,
        )
    }

    private var events: [String] {
        protocolEvents.withLock { $0 }
    }

    override func tearDown() {
        bargeIn.dispose()
        voiceActivity.dispose()
        super.tearDown()
    }

    func testSuspectSpeechDucksPlaybackWithoutCommitting() {
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)

        XCTAssertTrue(player.ducked)
        XCTAssertEqual(player.flushes, 0)
        XCTAssertTrue(playback.isHolding)
        XCTAssertEqual(events, ["assistant_playback_held"])
    }

    func testABriefLoudMomentBelowTheStreakIsNotEnoughOnItsOwn() {
        queueAssistantAudio()
        feedLoudUserChunks(count: 2)

        XCTAssertFalse(player.ducked)
        XCTAssertEqual(player.flushes, 0)
        XCTAssertTrue(events.isEmpty)
    }

    func testQuietUserAudioNeverInterrupts() {
        queueAssistantAudio()
        for _ in 0..<20 {
            voiceActivity.addUserChunk(conversationPcm(amplitude: 300))
            bargeIn.evaluate()
        }

        XCTAssertEqual(player.flushes, 0)
        XCTAssertTrue(events.isEmpty)
    }

    func testNothingToInterruptWithTheAssistantSilentAlready() {
        feedLoudUserChunks(count: 3)

        XCTAssertEqual(player.flushes, 0)
        XCTAssertTrue(events.isEmpty)
    }

    func testDrainedEvidenceResumesTheHeldTurnAndStartsCooldown() {
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)

        for _ in 0..<3 {
            voiceActivity.addUserChunk(conversationPcm(amplitude: 0))
            bargeIn.evaluate()
        }

        XCTAssertFalse(playback.isHolding)
        XCTAssertFalse(player.ducked)
        XCTAssertEqual(
            events,
            ["assistant_playback_held", "assistant_playback_resumed"],
        )
        // Nothing was taken off the player, so nothing has to go back.
        XCTAssertEqual(player.flushes, 0)
        XCTAssertEqual(player.enqueued.count, 1)
    }

    func testSustainedSpeechCommitsTheInterruption() {
        queueAssistantAudio()
        feedLoudUserChunks(count: 8)

        XCTAssertFalse(playback.isHolding)
        XCTAssertFalse(player.ducked)
        XCTAssertEqual(player.flushes, 1)
        XCTAssertEqual(
            events,
            ["assistant_playback_held", "assistant_interrupted"],
        )
    }

    func testFurtherSpeechAfterTheCutNeverRepeatsTheEvent() {
        queueAssistantAudio()
        feedLoudUserChunks(count: 12)

        XCTAssertEqual(
            events,
            ["assistant_playback_held", "assistant_interrupted"],
        )
    }

    func testHoldDeadlineExpiryResumesWithoutACommit() async {
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)

        XCTAssertEqual(events, ["assistant_playback_held"])

        // Leave the streak above zero so only the deadline can
        // resolve the hold — quiet chunks would resume through
        // evaluate() instead.
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(899))
        XCTAssertTrue(playback.isHolding)

        await clock.advance(by: .milliseconds(1))

        XCTAssertFalse(playback.isHolding)
        XCTAssertEqual(
            events,
            ["assistant_playback_held", "assistant_playback_resumed"],
        )
    }

    func testCancelHoldLetsTheDeadlinePassWithoutResuming() async {
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)
        await clock.waitForSleepers(1)

        bargeIn.cancelHold()
        await clock.advance(by: .seconds(5))

        XCTAssertTrue(playback.isHolding)
        XCTAssertEqual(events, ["assistant_playback_held"])
    }

    func testTheCooldownLapsesWithTheClock() async {
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)
        for _ in 0..<3 {
            voiceActivity.addUserChunk(conversationPcm(amplitude: 0))
            bargeIn.evaluate()
        }
        XCTAssertEqual(events.last, "assistant_playback_resumed")

        await clock.advance(by: .milliseconds(1_500))
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)

        XCTAssertTrue(playback.isHolding)
        XCTAssertEqual(
            events.filter { $0 == "assistant_playback_held" }.count,
            2,
        )
    }

    func testCooldownSuppressesNewHoldsButNotConfirmedInterrupts() {
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)
        for _ in 0..<3 {
            voiceActivity.addUserChunk(conversationPcm(amplitude: 0))
            bargeIn.evaluate()
        }
        XCTAssertEqual(events.last, "assistant_playback_resumed")

        queueAssistantAudio()

        // Still inside the cooldown: three loud chunks would
        // otherwise hold.
        feedLoudUserChunks(count: 3)
        XCTAssertFalse(playback.isHolding)
        XCTAssertFalse(player.ducked)
        XCTAssertEqual(
            events.filter { $0 == "assistant_playback_held" }.count,
            1,
        )

        // Sustained speech still cuts through during the rest.
        feedLoudUserChunks(count: 5)
        XCTAssertTrue(events.contains("assistant_interrupted"))
    }

    func testAScreenTouchKeepsTheBurstItMakesFromHolding() async {
        queueAssistantAudio()
        bargeIn.noteScreenTouch()
        feedLoudUserChunks(count: 3)

        XCTAssertFalse(playback.isHolding)
        XCTAssertEqual(player.flushes, 0)
        XCTAssertTrue(events.isEmpty)

        // Once the grace lapses the same burst holds as before.
        await clock.advance(by: .milliseconds(400))
        for _ in 0..<3 {
            voiceActivity.addUserChunk(conversationPcm(amplitude: 0))
            bargeIn.evaluate()
        }
        feedLoudUserChunks(count: 3)

        XCTAssertTrue(playback.isHolding)
        XCTAssertEqual(events, ["assistant_playback_held"])
    }

    func testAScreenTouchDoesNotDisturbAHoldAlreadyInProgress() {
        queueAssistantAudio()
        feedLoudUserChunks(count: 3)
        XCTAssertTrue(playback.isHolding)

        bargeIn.noteScreenTouch()
        for _ in 0..<3 {
            voiceActivity.addUserChunk(conversationPcm(amplitude: 0))
            bargeIn.evaluate()
        }

        XCTAssertFalse(playback.isHolding)
        XCTAssertEqual(
            events,
            ["assistant_playback_held", "assistant_playback_resumed"],
        )
    }

    private func queueAssistantAudio() {
        let chunk = conversationPcm(
            amplitude: 8_000,
            milliseconds: 1_000,
        )
        _ = playback.enqueue(chunk)
        voiceActivity.addAiChunk(chunk)
    }

    private func feedLoudUserChunks(count: Int) {
        for _ in 0..<count {
            voiceActivity.addUserChunk(
                conversationPcm(amplitude: 20_000),
            )
            bargeIn.evaluate()
        }
    }
}
