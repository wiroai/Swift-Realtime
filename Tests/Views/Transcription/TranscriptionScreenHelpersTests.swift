import XCTest
@testable import SwiftRealtime

final class TranscriptionScreenHelpersTests: XCTestCase {
    func testConnectingIsOnlyTheWaitBetweenTapAndStream() {
        var state = SpeechToTextState(
            sessionState: .creatingTask,
        )
        XCTAssertTrue(state.showsConnecting)
        XCTAssertFalse(state.isLive)

        state.sessionState = .streaming
        XCTAssertFalse(state.showsConnecting)
        XCTAssertTrue(state.isLive)

        state.sessionState = .stopping
        XCTAssertTrue(state.isEnding)
        XCTAssertFalse(state.showsConnecting)
    }

    func testClearIsIdleAndNonEmptyOnly() {
        var state = SpeechToTextState(transcript: "hello")
        XCTAssertTrue(state.canClearTranscript)

        state.sessionState = .streaming
        XCTAssertFalse(state.canClearTranscript)

        state.sessionState = .completed
        state.transcript = ""
        XCTAssertFalse(state.canClearTranscript)
    }

    func testDelayFieldComesFromTheCatalog() {
        XCTAssertEqual(
            TranscriptionFields.delay(
                in: WiroModelCatalog.voxtralMiniRealtime,
            )?.id,
            TranscriptionFields.delayId,
        )
    }
}
