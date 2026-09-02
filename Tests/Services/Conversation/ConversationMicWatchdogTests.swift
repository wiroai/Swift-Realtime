import os
import XCTest
@testable import SwiftRealtime

final class ConversationMicWatchdogTests: XCTestCase {
    private var clock: TestClock!
    private var stalls: OSAllocatedUnfairLock<Int>!

    override func setUp() {
        super.setUp()
        clock = TestClock()
        stalls = OSAllocatedUnfairLock(initialState: 0)
    }

    private var stallCount: Int {
        stalls.withLock(\.self)
    }

    private func makeWatchdog() -> ConversationMicWatchdog {
        let stalls = stalls!
        return ConversationMicWatchdog(
            onStall: { stalls.withLock { $0 += 1 } },
            stallTimeout: .seconds(3),
            clock: clock,
        )
    }

    func testTheWatchdogFiresAfterSilence() async {
        let watchdog = makeWatchdog()

        watchdog.start()
        await clock.waitForSleepers(1)
        XCTAssertEqual(stallCount, 0)

        // Ticks every half timeout: 1.5 s is a check that still
        // passes, 3 s is the first one that trips.
        await clock.advance(by: .milliseconds(1_500))
        XCTAssertEqual(stallCount, 0)
        await clock.advance(by: .milliseconds(1_500))
        XCTAssertEqual(stallCount, 1)

        watchdog.dispose()
    }

    func testTheWatchdogStaysQuietWhileChunksFlow() async {
        let watchdog = makeWatchdog()

        watchdog.start()
        await clock.waitForSleepers(1)
        for _ in 0..<8 {
            await clock.advance(by: .seconds(1))
            watchdog.markAlive()
        }

        XCTAssertEqual(stallCount, 0)
        watchdog.dispose()
    }

    func testStopSilencesTheTimer() async {
        let watchdog = makeWatchdog()

        watchdog.start()
        await clock.waitForSleepers(1)
        watchdog.stop()
        await clock.advance(by: .seconds(30))

        XCTAssertEqual(stallCount, 0)
        watchdog.dispose()
    }

    func testADisposedWatchdogNeverFires() async {
        let watchdog = makeWatchdog()

        watchdog.dispose()
        watchdog.start()
        await clock.advance(by: .seconds(30))

        XCTAssertEqual(stallCount, 0)
        XCTAssertEqual(clock.sleeperCount, 0)
    }
}
