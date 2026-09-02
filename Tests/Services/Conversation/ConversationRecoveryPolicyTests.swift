import os
import XCTest
@testable import SwiftRealtime

final class ConversationRecoveryPolicyTests: XCTestCase {
    private var clock: TestClock!
    private var policy: ConversationRecoveryPolicy!

    override func setUp() {
        super.setUp()
        clock = TestClock()
        policy = ConversationRecoveryPolicy(
            maxRetryAttempts: 2,
            retryBaseDelay: .milliseconds(100),
            autoRestartDelay: .seconds(5),
            clock: clock,
        )
    }

    override func tearDown() {
        policy.dispose()
        super.tearDown()
    }

    func testRetriesARecoverableFailureUntilTheBudgetIsSpent() {
        let error = WiroFailure.socketConnection

        XCTAssertTrue(
            policy.shouldRetry(error, isReconfiguring: false),
        )
        policy.noteRetryScheduled()
        XCTAssertTrue(
            policy.shouldRetry(error, isReconfiguring: false),
        )
        policy.noteRetryScheduled()
        XCTAssertFalse(
            policy.shouldRetry(error, isReconfiguring: false),
        )
    }

    func testReconfiguringBlocksRetries() {
        XCTAssertFalse(
            policy.shouldRetry(
                WiroFailure.socketConnection,
                isReconfiguring: true,
            ),
        )
    }

    func testClassifiesRecoverableAndUnrecoverableFailures() {
        let recoverable: [Error] = [
            WiroFailure.serverUnavailable,
            WiroFailure.networkUnavailable,
            WiroFailure.requestTimeout,
            WiroFailure.socketConnection,
            WiroFailure.socketConnectTimeout,
            WiroFailure.streamReadyTimeout,
            AudioFailure.capture,
            AudioFailure.playback,
        ]
        for error in recoverable {
            XCTAssertTrue(
                policy.isRecoverable(error),
                "\(error)",
            )
        }

        let unrecoverable: [Error] = [
            WiroFailure.authentication,
            WiroFailure.apiRejected,
            WiroFailure.cancelled,
            WiroFailure.sessionBusy,
        ]
        for error in unrecoverable {
            XCTAssertFalse(
                policy.isRecoverable(error),
                "\(error)",
            )
        }
        XCTAssertFalse(
            policy.isRecoverable(CancellationError()),
        )
    }

    func testRetryBackoffDoublesFromTheBaseDelay() {
        policy.noteRetryScheduled()
        XCTAssertEqual(policy.nextRetryDelay, .milliseconds(100))
        XCTAssertEqual(policy.retryAttempt, 1)

        policy.noteRetryScheduled()
        XCTAssertEqual(policy.nextRetryDelay, .milliseconds(200))

        policy.noteRetryScheduled()
        XCTAssertEqual(policy.nextRetryDelay, .milliseconds(400))
    }

    func testAutoRestartBudgetSpendsAndRefillsOnAHealthySend() async {
        let restarts = OSAllocatedUnfairLock(initialState: 0)
        let restart: @Sendable () -> Void = {
            restarts.withLock { $0 += 1 }
        }

        XCTAssertTrue(policy.scheduleAutoRestart(restart))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(5))
        XCTAssertEqual(restarts.withLock(\.self), 1)

        XCTAssertTrue(policy.scheduleAutoRestart(restart))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(10))
        XCTAssertEqual(restarts.withLock(\.self), 2)

        XCTAssertFalse(policy.scheduleAutoRestart(restart))

        policy.noteHealthy()
        XCTAssertTrue(policy.scheduleAutoRestart(restart))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(5))
        XCTAssertEqual(restarts.withLock(\.self), 3)
    }

    func testAutoRestartDelayCapsAtFourTimesTheBase() async {
        let fired = OSAllocatedUnfairLock(initialState: 0)
        let restart: @Sendable () -> Void = {
            fired.withLock { $0 += 1 }
        }
        let wide = ConversationRecoveryPolicy(
            autoRestartDelay: .seconds(1),
            maxAutoRestarts: 4,
            clock: clock,
        )
        defer { wide.dispose() }

        // Cycle 1: base delay.
        XCTAssertTrue(wide.scheduleAutoRestart(restart))
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(999))
        XCTAssertEqual(fired.withLock(\.self), 0)
        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(fired.withLock(\.self), 1)

        // Cycle 2: doubled.
        XCTAssertTrue(wide.scheduleAutoRestart(restart))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(2))
        XCTAssertEqual(fired.withLock(\.self), 2)

        // Cycle 3: quadrupled.
        XCTAssertTrue(wide.scheduleAutoRestart(restart))
        await clock.waitForSleepers(1)
        await clock.advance(by: .seconds(4))
        XCTAssertEqual(fired.withLock(\.self), 3)

        // Cycle 4: still quadrupled, never eightfold.
        XCTAssertTrue(wide.scheduleAutoRestart(restart))
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(3_999))
        XCTAssertEqual(fired.withLock(\.self), 3)
        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(fired.withLock(\.self), 4)
    }

    func testCancelAutoRestartDropsTheArmedRestart() async {
        let fired = OSAllocatedUnfairLock(initialState: 0)

        XCTAssertTrue(
            policy.scheduleAutoRestart { fired.withLock { $0 += 1 } },
        )
        await clock.waitForSleepers(1)
        policy.cancelAutoRestart()
        await clock.advance(by: .seconds(30))

        XCTAssertEqual(fired.withLock(\.self), 0)
    }
}
