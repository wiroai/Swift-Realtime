import XCTest
@testable import SwiftRealtime

final class RealtimeSessionGuardTests: XCTestCase {
    func testAllowsOneLeaseAndRejectsParallelSessions() {
        let sessionGuard = RealtimeSessionGuard()
        let conversation = sessionGuard.acquire(.conversation)
        let transcription = sessionGuard.acquire(.transcription)

        XCTAssertNotNil(conversation)
        XCTAssertNil(transcription)
        XCTAssertEqual(sessionGuard.currentLease, conversation)
        sessionGuard.dispose()
    }

    func testOnlyTheCurrentLeaseCanReleaseTheGuard() {
        let sessionGuard = RealtimeSessionGuard()
        let first = sessionGuard.acquire(.speech)
        sessionGuard.release(first)
        let second = sessionGuard.acquire(.speech)

        sessionGuard.release(first)

        XCTAssertEqual(sessionGuard.currentLease, second)
        sessionGuard.dispose()
    }

    func testAcquireWhenFreeAcquiresImmediatelyWhenNothingIsHeld() async {
        let sessionGuard = RealtimeSessionGuard()
        let lease = await sessionGuard.acquireWhenFree(.conversation)

        XCTAssertNotNil(lease)
        XCTAssertEqual(sessionGuard.currentLease, lease)
        sessionGuard.dispose()
    }

    func testAcquireWhenFreeWaitsOutTheDepartingSession() async {
        let sessionGuard = RealtimeSessionGuard()
        let departing = sessionGuard.acquire(.conversation)

        let pending = Task {
            await sessionGuard.acquireWhenFree(.transcription)
        }
        try? await Task.sleep(for: .milliseconds(20))
        sessionGuard.release(departing)

        let lease = await pending.value
        XCTAssertEqual(lease?.owner, .transcription)
        XCTAssertEqual(sessionGuard.currentLease, lease)
        sessionGuard.dispose()
    }

    func testAcquireWhenFreeGivesUpOnceNothingLetsGo() async {
        let sessionGuard = RealtimeSessionGuard()
        _ = sessionGuard.acquire(.conversation)

        let lease = await sessionGuard.acquireWhenFree(
            .speech,
            timeout: .milliseconds(20),
        )

        XCTAssertNil(lease)
        sessionGuard.dispose()
    }

    func testDisposalWakesAPendingAcquireWhenFreeWithNothing() async {
        let sessionGuard = RealtimeSessionGuard()
        _ = sessionGuard.acquire(.conversation)
        let pending = Task {
            await sessionGuard.acquireWhenFree(.speech)
        }
        try? await Task.sleep(for: .milliseconds(20))
        sessionGuard.dispose()

        let lease = await pending.value
        XCTAssertNil(lease)
    }

    func testIgnoresAsynchronousReleaseAfterDisposal() {
        let sessionGuard = RealtimeSessionGuard()
        let lease = sessionGuard.acquire(.conversation)

        sessionGuard.dispose()
        sessionGuard.release(lease)

        XCTAssertNil(sessionGuard.acquire(.transcription))
    }
}
