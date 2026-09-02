import XCTest
@testable import SwiftRealtime

final class RealtimeEventParserTests: XCTestCase {
    private let parser = RealtimeEventParser()

    func testParsesKnownRealtimeStatusEvents() {
        let event = parser.parse(.text("{\"type\":\"task_stream_ready\"}"))

        XCTAssertEqual(event, .status(.streamReady))
    }

    func testParsesProgressiveTranscriptOutput() {
        let event = parser.parse(
            .text(
                "{\"type\":\"task_output\","
                    + "\"message\":\"TRANSCRIPT_USER:Hello\"}",
            ),
        )

        XCTAssertEqual(event, .output("TRANSCRIPT_USER:Hello"))
    }

    func testDoesNotRetainRawServerErrorDetails() {
        let event = parser.parse(
            .text(
                "{\"type\":\"task_error\","
                    + "\"message\":\"secret server detail\"}",
            ),
        )

        XCTAssertEqual(event, .error(wireType: "task_error"))
        XCTAssertFalse(String(describing: event).contains("secret"))
    }

    func testParsesBinaryFramesWithoutDecodingAudio() {
        let event = parser.parse(.binary(Data([1, 2, 3])))

        XCTAssertEqual(event, .binary(Data([1, 2, 3])))
    }

    func testKeepsUnknownEventTypesForwardCompatible() {
        let event = parser.parse(.text("{\"type\":\"task_future_event\"}"))

        XCTAssertEqual(event, .unknown(wireType: "task_future_event"))
    }

    func testMapsInvalidFramesToAMalformedEvent() {
        XCTAssertEqual(parser.parse(.text("not-json")), .malformed)
        XCTAssertEqual(
            parser.parse(.text("{\"message\":\"missing type\"}")),
            .malformed,
        )
    }
}
