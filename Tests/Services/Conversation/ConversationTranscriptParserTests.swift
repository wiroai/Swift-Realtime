import XCTest
@testable import SwiftRealtime

final class ConversationTranscriptParserTests: XCTestCase {
    private let parser = ConversationTranscriptParser()

    func testAssignsAPrefixedUserLineToTheUser() {
        let transcript = parser.parse("TRANSCRIPT_USER:hello there")

        guard case let .user(text) = transcript else {
            return XCTFail("expected a user transcript")
        }
        XCTAssertEqual(text, "hello there")
    }

    func testAssignsAPrefixedAssistantLineToTheAssistant() {
        let transcript = parser.parse("TRANSCRIPT_AI:how can I help")

        guard case let .ai(text) = transcript else {
            return XCTFail("expected an AI transcript")
        }
        XCTAssertEqual(text, "how can I help")
    }

    func testReturnsNilForOutputThatIsNotATranscript() {
        XCTAssertNil(parser.parse("task cost: 0.01"))
        XCTAssertNil(parser.parse(""))
    }

    func testKeepsThePayloadVerbatimIncludingColons() {
        let transcript = parser.parse(
            "TRANSCRIPT_AI: sure: 10:30 works ",
        )

        XCTAssertEqual(transcript?.text, " sure: 10:30 works ")
    }

    func testAnEmptyPayloadYieldsAnEmptyTranscript() {
        let transcript = parser.parse("TRANSCRIPT_USER:")

        guard case let .user(text) = transcript else {
            return XCTFail("expected a user transcript")
        }
        XCTAssertEqual(text, "")
    }

    func testAPrefixInTheMiddleOfAMessageIsNotATranscript() {
        XCTAssertNil(parser.parse("log TRANSCRIPT_USER:hello"))
    }
}
