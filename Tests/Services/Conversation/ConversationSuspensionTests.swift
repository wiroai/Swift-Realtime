import os
import XCTest
@testable import SwiftRealtime

final class ConversationSuspensionTests: XCTestCase {
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        clock = TestClock()
    }

    func testAZeroGracePeriodHoldsNothing() {
        let hold = ConversationSuspension(
            gracePeriod: .zero,
            clock: clock,
            onExpired: {},
        )

        XCTAssertFalse(hold.holdsAnything)
        hold.dispose()
    }

    func testAPositiveGracePeriodCanHoldAConversation() {
        let hold = ConversationSuspension(
            gracePeriod: .seconds(5),
            clock: clock,
            onExpired: {},
        )

        XCTAssertTrue(hold.holdsAnything)
        hold.dispose()
    }

    func testTheTimerHangsUpAfterTheGracePeriod() async {
        let expired = OSAllocatedUnfairLock(initialState: 0)
        let hold = ConversationSuspension(
            gracePeriod: .seconds(5),
            clock: clock,
            onExpired: { expired.withLock { $0 += 1 } },
        )

        hold.begin()
        XCTAssertFalse(hold.hasLapsed)
        await clock.waitForSleepers(1)

        await clock.advance(by: .seconds(4))
        XCTAssertEqual(expired.withLock(\.self), 0)
        XCTAssertFalse(hold.hasLapsed)

        await clock.advance(by: .seconds(1))
        XCTAssertEqual(expired.withLock(\.self), 1)
        hold.dispose()
    }

    func testCancelStopsTheTimerTheClockCanStillLapse() async {
        let expired = OSAllocatedUnfairLock(initialState: 0)
        let hold = ConversationSuspension(
            gracePeriod: .seconds(5),
            clock: clock,
            onExpired: { expired.withLock { $0 += 1 } },
        )

        hold.begin()
        await clock.waitForSleepers(1)
        hold.cancel()

        // A frozen app runs no timers; the clock alone decides.
        await clock.advance(by: .seconds(6))

        XCTAssertEqual(expired.withLock(\.self), 0)
        XCTAssertTrue(hold.hasLapsed)
        hold.dispose()
    }

    func testClearForgetsTheHoldSoALaterResumeIsALapse() {
        let hold = ConversationSuspension(
            gracePeriod: .seconds(5),
            clock: clock,
            onExpired: {},
        )

        hold.begin()
        hold.clear()

        XCTAssertTrue(hold.hasLapsed)
        hold.dispose()
    }

    func testADisposedHoldNeverExpires() async {
        let expired = OSAllocatedUnfairLock(initialState: 0)
        let hold = ConversationSuspension(
            gracePeriod: .seconds(5),
            clock: clock,
            onExpired: { expired.withLock { $0 += 1 } },
        )

        hold.begin()
        await clock.waitForSleepers(1)
        hold.dispose()
        await clock.advance(by: .seconds(10))

        XCTAssertEqual(expired.withLock(\.self), 0)
    }
}
