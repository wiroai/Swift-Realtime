import XCTest
@testable import SwiftRealtime

final class ProtocolEventLogTests: XCTestCase {
    func testAppendsEventsOldestFirst() {
        let log = ProtocolEventLog()
        _ = log.add("first")
        let events = log.add("second")

        XCTAssertEqual(events, ["first", "second"])
        XCTAssertEqual(log.events, ["first", "second"])
    }

    func testDropsTheOldestEventsPastTheMaximum() {
        let log = ProtocolEventLog(maximumEvents: 3)
        for event in ["a", "b", "c", "d", "e"] {
            log.add(event)
        }
        XCTAssertEqual(log.events, ["c", "d", "e"])
    }

    func testNeverExceedsTheDefaultMaximumAcrossALongSession() {
        let log = ProtocolEventLog()
        for index in 0..<500 {
            log.add("event_\(index)")
        }
        XCTAssertEqual(log.events.count, 40)
        XCTAssertEqual(log.events.first, "event_460")
        XCTAssertEqual(log.events.last, "event_499")
    }

    func testClearResetsTheHistoryWithoutBreakingLaterAppends() {
        let log = ProtocolEventLog()
        log.add("stale")
        log.clear()
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(log.add("fresh"), ["fresh"])
    }
}
