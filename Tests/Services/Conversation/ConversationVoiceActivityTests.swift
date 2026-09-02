import XCTest
@testable import SwiftRealtime

final class ConversationVoiceActivityTests: XCTestCase {
    private var activity: ConversationVoiceActivity!

    override func setUp() {
        super.setUp()
        activity = ConversationVoiceActivity()
    }

    override func tearDown() {
        activity.dispose()
        super.tearDown()
    }

    func testAssistantAudioOwnsThePhaseUntilThePlayheadPasses() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )

        XCTAssertEqual(activity.phase, .aiSpeaking)
        XCTAssertGreaterThan(activity.aiLevel, 0)

        activity.resetAi()

        XCTAssertEqual(activity.phase, .quiet)
        XCTAssertEqual(activity.aiLevel, 0)
    }

    func testALoudUserTakesTheFloorFromATalkingAssistant() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )
        activity.addUserChunk(
            conversationPcm(amplitude: 20_000, milliseconds: 20),
        )

        XCTAssertEqual(activity.phase, .userSpeaking)
    }

    func testABurstOfLoudChunksRaisesSuspicionBeforeConfirmation() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )
        activity.addUserChunk(
            conversationPcm(amplitude: 20_000, milliseconds: 20),
        )
        activity.addUserChunk(
            conversationPcm(amplitude: 20_000, milliseconds: 20),
        )

        XCTAssertFalse(activity.userMaybeInterrupting)

        activity.addUserChunk(
            conversationPcm(amplitude: 20_000, milliseconds: 20),
        )

        XCTAssertTrue(activity.userMaybeInterrupting)
        XCTAssertFalse(activity.userInterrupting)

        activity.resetAi()

        XCTAssertFalse(activity.userMaybeInterrupting)
    }

    func testSustainedLoudSpeechConfirmsTheInterruption() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )

        for _ in 0..<8 {
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
        }

        XCTAssertTrue(activity.userInterrupting)

        activity.resetAi()

        XCTAssertFalse(activity.userInterrupting)
    }

    func testNaturalSpeechWithBriefDipsStillConfirms() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )

        for _ in 0..<5 {
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
            activity.addUserChunk(
                conversationPcm(amplitude: 0, milliseconds: 20),
            )
        }
        activity.addUserChunk(
            conversationPcm(amplitude: 20_000, milliseconds: 20),
        )

        XCTAssertTrue(activity.userInterrupting)
    }

    func testSyllableDipsAboveTheSustainLevelKeepTheEvidence() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )

        for _ in 0..<3 {
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
        }
        for _ in 0..<5 {
            activity.addUserChunk(
                conversationPcm(amplitude: 1_500, milliseconds: 20),
            )
        }
        XCTAssertTrue(activity.userMaybeInterrupting)

        for _ in 0..<5 {
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
        }

        XCTAssertTrue(activity.userInterrupting)
    }

    func testNoiseBurstsNeverConfirmAndTheirEvidenceDrains() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )

        for _ in 0..<6 {
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
            activity.addUserChunk(
                conversationPcm(amplitude: 20_000, milliseconds: 20),
            )
            for _ in 0..<5 {
                activity.addUserChunk(
                    conversationPcm(amplitude: 0, milliseconds: 20),
                )
            }
        }

        XCTAssertFalse(activity.userInterrupting)
        XCTAssertFalse(activity.hasInterruptEvidence)
    }

    func testQuietSpeechNeverCountsAsAnInterruption() {
        activity.addAiChunk(
            conversationPcm(amplitude: 8_000, milliseconds: 2_000),
        )

        for _ in 0..<10 {
            activity.addUserChunk(
                conversationPcm(amplitude: 900, milliseconds: 20),
            )
        }

        XCTAssertFalse(activity.userInterrupting)
        XCTAssertEqual(activity.phase, .aiSpeaking)
    }
}
