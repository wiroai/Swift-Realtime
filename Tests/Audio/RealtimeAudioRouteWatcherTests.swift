import os
import XCTest
@testable import SwiftRealtime

final class RealtimeAudioRouteWatcherTests: XCTestCase {
    func testBeginningInterruptionRequestsAStop() async {
        let harness = Harness()
        harness.session.emitInterruption(.began)
        await waitUntil { harness.stopRequests.withLock { $0 } == 1 }
        XCTAssertEqual(harness.stopRequests.withLock { $0 }, 1)
        await harness.dispose()
    }

    func testEndingInterruptionDoesNotRequestAStop() async {
        let harness = Harness()
        harness.session.emitInterruption(.ended)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.stopRequests.withLock { $0 }, 0)
        await harness.dispose()
    }

    func testUnpluggingTheOutputRouteRequestsAStop() async {
        let harness = Harness()
        harness.session.emitBecomingNoisy()
        await waitUntil { harness.stopRequests.withLock { $0 } == 1 }
        XCTAssertEqual(harness.stopRequests.withLock { $0 }, 1)
        await harness.dispose()
    }

    func testARouteChangeIsReportedSeparatelyFromAStop() async {
        let harness = Harness()
        harness.session.emitRouteChange()
        await waitUntil { harness.routeChanges.withLock { $0 } == 1 }
        XCTAssertEqual(harness.routeChanges.withLock { $0 }, 1)
        XCTAssertEqual(harness.stopRequests.withLock { $0 }, 0)
        await harness.dispose()
    }

    func testPlaybackFailuresReachTheCallerUnchanged() async {
        let harness = Harness()
        harness.failureContinuation.yield(.playback)
        await waitUntil {
            harness.failures.withLock { $0 } == [.playback]
        }
        XCTAssertEqual(harness.failures.withLock { $0 }, [.playback])
        await harness.dispose()
    }

    func testDisposalDetachesEverySource() async {
        let harness = Harness()
        await harness.watcher.dispose()

        harness.session.emitInterruption(.began)
        harness.session.emitBecomingNoisy()
        harness.session.emitRouteChange()
        harness.failureContinuation.yield(.playback)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(harness.stopRequests.withLock { $0 }, 0)
        XCTAssertEqual(harness.routeChanges.withLock { $0 }, 0)
        XCTAssertTrue(harness.failures.withLock { $0 }.isEmpty)
        await harness.session.dispose()
        harness.failureContinuation.finish()
    }
}

private final class Harness: @unchecked Sendable {
    let session = FakeRealtimeAudioSession()
    let stopRequests = OSAllocatedUnfairLock(initialState: 0)
    let routeChanges = OSAllocatedUnfairLock(initialState: 0)
    let failures = OSAllocatedUnfairLock(
        initialState: [AudioFailure](),
    )
    let failureStream: AsyncStream<AudioFailure>
    let failureContinuation: AsyncStream<AudioFailure>.Continuation
    let watcher: RealtimeAudioRouteWatcher

    init() {
        let pair = AsyncStream<AudioFailure>.makeStream()
        failureStream = pair.stream
        failureContinuation = pair.continuation
        let stops = stopRequests
        let routes = routeChanges
        let recorded = failures
        watcher = RealtimeAudioRouteWatcher(
            audioSession: session,
            playbackFailures: failureStream,
            onShouldStop: { stops.withLock { $0 += 1 } },
            onRouteChanged: { routes.withLock { $0 += 1 } },
            onPlaybackFailure: { failure in
                recorded.withLock { $0.append(failure) }
            },
        )
    }

    func dispose() async {
        await watcher.dispose()
        await session.dispose()
        failureContinuation.finish()
    }
}
