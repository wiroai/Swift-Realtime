import Foundation
import os
import XCTest
@testable import SwiftRealtime

/// A clock that only moves when a test says so.
///
/// Sleepers park until `advance(by:)` carries `now` past their
/// deadline. Time advances one deadline at a time and yields between
/// them, so a periodic timer that re-arms itself after each tick is
/// woken once per period rather than skipped.
final class TestClock: RealtimeClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: ContinuousClock.Instant
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init() {
        state = OSAllocatedUnfairLock(
            initialState: State(now: ContinuousClock.now),
        )
    }

    var now: ContinuousClock.Instant {
        state.withLock(\.now)
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let wake: Result<Void, any Error>? = state.withLock {
                    state in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    let deadline = state.now + duration
                    if deadline <= state.now {
                        return .success(())
                    }
                    state.sleepers[id] = Sleeper(
                        deadline: deadline,
                        continuation: continuation,
                    )
                    return nil
                }
                if let wake {
                    continuation.resume(with: wake)
                }
            }
        } onCancel: {
            let sleeper = state.withLock {
                $0.sleepers.removeValue(forKey: id)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Waits until `count` tasks are parked in `sleep`, so a test can
    /// arm a timer and be sure it is listening before moving time.
    func waitForSleepers(
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        for _ in 0..<200 {
            if sleeperCount >= count {
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(
            "Expected \(count) sleeper(s), found \(sleeperCount)",
            file: file,
            line: line,
        )
    }

    /// Moves `now` forward, waking every sleeper whose deadline it
    /// passes, in deadline order.
    func advance(by duration: Duration) async {
        let target = now + duration
        while let next = wakeNext(upTo: target) {
            next.continuation.resume()
            await settle()
        }
        state.withLock { $0.now = target }
        await settle()
    }

    private func wakeNext(
        upTo target: ContinuousClock.Instant,
    ) -> Sleeper? {
        state.withLock { state in
            guard let (id, sleeper) = state.sleepers.min(by: {
                $0.value.deadline < $1.value.deadline
            }), sleeper.deadline <= target
            else {
                return nil
            }
            state.sleepers.removeValue(forKey: id)
            state.now = sleeper.deadline
            return sleeper
        }
    }

    /// Lets a woken task run to its next suspension point before the
    /// clock moves again.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
