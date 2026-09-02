import os
import XCTest
@testable import SwiftRealtime

final class ConversationTurnTakingTests: XCTestCase {
    private var player: FakeConversationPlayer!
    private var events: OSAllocatedUnfairLock<[String]>!

    override func setUp() {
        super.setUp()
        player = FakeConversationPlayer()
        events = OSAllocatedUnfairLock(initialState: [])
    }

    private func makeTurnTaking(
        noiseGate: PcmNoiseGate? = nil,
    ) -> ConversationTurnTaking {
        let events = events!
        return ConversationTurnTaking(
            player: player,
            noiseGate: noiseGate,
            holdTimeout: .milliseconds(900),
            holdCooldown: .milliseconds(1_500),
            onEvent: { event in
                events.withLock { $0.append(event) }
            },
        )
    }

    func testWithoutAGateTheChunkIsMeasuredAndPassedThrough() {
        let turnTaking = makeTurnTaking()
        let chunk = conversationPcm(amplitude: 15_000)

        let gated = turnTaking.gate(chunk)

        XCTAssertEqual(gated.gated, chunk)
        XCTAssertEqual(gated.level, pcmNormalizedLevel(chunk))
        turnTaking.dispose()
    }

    func testWithAGateTheMeasuredLevelIsTheGatedOutput() {
        let gate = PcmNoiseGate()
        let turnTaking = makeTurnTaking(noiseGate: gate)
        let chunk = conversationPcm(amplitude: 300)

        let gated = turnTaking.gate(chunk)

        XCTAssertNotEqual(gated.gated, chunk)
        XCTAssertEqual(gated.level, gate.lastOutputLevel)
        XCTAssertLessThan(gated.level, pcmNormalizedLevel(chunk))
        turnTaking.dispose()
    }

    func testAssistantAudioReachesThePlayerAndCountsAsAudible() async throws {
        let turnTaking = makeTurnTaking()
        try await player.start()
        let chunk = conversationPcm(amplitude: 8_000)

        let outcome = turnTaking.acceptAssistantAudio(chunk)

        XCTAssertFalse(outcome.droppedChunk)
        XCTAssertEqual(player.fedChunks, [chunk])
        XCTAssertTrue(turnTaking.assistantAudible)
        turnTaking.dispose()
    }

    func testAnExplicitInterruptionSilencesTheRestOfTheTurn() async throws {
        let turnTaking = makeTurnTaking()
        try await player.start()
        _ = turnTaking.acceptAssistantAudio(
            conversationPcm(amplitude: 8_000),
        )

        XCTAssertTrue(turnTaking.interruptAssistant())
        XCTAssertEqual(player.flushCalls, 1)
        XCTAssertFalse(turnTaking.assistantAudible)

        let straggler = turnTaking.acceptAssistantAudio(
            conversationPcm(amplitude: 8_000),
        )
        XCTAssertTrue(straggler.silencedChunk)
        XCTAssertTrue(player.fedChunks.isEmpty)
        turnTaking.dispose()
    }

    func testInterruptingWithNothingAudibleDoesNothing() {
        let turnTaking = makeTurnTaking()

        XCTAssertFalse(turnTaking.interruptAssistant())
        XCTAssertEqual(player.flushCalls, 0)
        turnTaking.dispose()
    }

    func testResetForgetsTheTurnInProgress() async throws {
        let turnTaking = makeTurnTaking()
        try await player.start()
        _ = turnTaking.acceptAssistantAudio(
            conversationPcm(amplitude: 8_000),
        )
        XCTAssertTrue(turnTaking.interruptAssistant())

        turnTaking.reset()

        let next = turnTaking.acceptAssistantAudio(
            conversationPcm(amplitude: 8_000),
        )
        XCTAssertFalse(next.silencedChunk)
        XCTAssertFalse(next.droppedChunk)
        turnTaking.dispose()
    }
}
