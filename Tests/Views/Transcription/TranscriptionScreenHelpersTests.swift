import XCTest
@testable import SwiftRealtime

final class TranscriptionScreenHelpersTests: XCTestCase {
    func testConnectCaptionsNameTheWaitThePersonIsIn() {
        XCTAssertEqual(
            TranscriptionConnectProgress.caption(
                for: .requestingPermission,
            ),
            TranscriptionCopy.connectingPermission,
        )
        XCTAssertEqual(
            TranscriptionConnectProgress.caption(
                for: .creatingTask,
            ),
            TranscriptionCopy.startingTask,
        )
        XCTAssertEqual(
            TranscriptionConnectProgress.caption(for: .stopping),
            TranscriptionCopy.finishing,
        )
        XCTAssertNil(
            TranscriptionConnectProgress.caption(for: .streaming),
        )
        XCTAssertNil(
            TranscriptionConnectProgress.caption(for: .idle),
        )
    }

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

    func testCopyActionIsTheDartWording() {
        XCTAssertEqual(TranscriptionCopy.copy, "Copy")
    }

    func testDisplayNameCapitalizesTheFirstLetter() {
        XCTAssertEqual(
            TranscriptionFields.displayName("balanced"),
            "Balanced",
        )
        XCTAssertEqual(TranscriptionFields.displayName(""), "")
    }
}
