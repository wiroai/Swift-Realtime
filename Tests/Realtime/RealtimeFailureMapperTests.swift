import XCTest
@testable import SwiftRealtime

final class RealtimeFailureMapperTests: XCTestCase {
    private let mapper = RealtimeFailureMapper(
        fallbackMessage: "Session failed.",
    )

    func testPassesThroughWiroFailureMessagesAndCodes() {
        let failure = WiroFailure.socketConnection
        XCTAssertEqual(mapper.message(for: failure), failure.message)
        XCTAssertEqual(mapper.code(for: failure), "socketConnection")
    }

    func testPassesThroughAudioFailureMessagesAndCodes() {
        XCTAssertEqual(
            mapper.message(for: AudioFailure.playback),
            AudioFailure.playback.message,
        )
        XCTAssertEqual(
            mapper.code(for: AudioFailure.playback),
            "playbackUnavailable",
        )
    }

    func testCollapsesUnrecognisedErrorsToTheFallback() {
        XCTAssertEqual(
            mapper.message(for: CancellationError()),
            "Session failed.",
        )
        XCTAssertEqual(
            mapper.code(for: CancellationError()),
            RealtimeFailureMapper.unknownCode,
        )
    }

    func testNeverLeaksRawExceptionDetailIntoTheMessage() {
        struct Leaky: Error, CustomStringConvertible {
            var description: String {
                "tasktoken=super-secret-value"
            }
        }
        let leaky = Leaky()
        XCTAssertEqual(mapper.message(for: leaky), "Session failed.")
        XCTAssertFalse(mapper.message(for: leaky).contains("secret"))
    }

    func testEachFeatureCanSupplyItsOwnFallbackWording() {
        let transcription = RealtimeFailureMapper(
            fallbackMessage:
            "The transcription session could not be completed.",
        )
        XCTAssertEqual(
            transcription.message(for: CancellationError()),
            "The transcription session could not be completed.",
        )
        XCTAssertEqual(
            mapper.message(for: CancellationError()),
            "Session failed.",
        )
    }
}
