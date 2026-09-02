import Foundation

/// The clock session code reads and sleeps on.
///
/// Hold timers, restart backoff, and stall detection are all "did
/// enough time pass" questions. Asking them through one injectable
/// clock lets a test move time by hand instead of waiting on the wall,
/// which is the difference between a suite that is deterministic and
/// one that is merely fast enough on a quiet machine.
///
/// `ContinuousClock` is the production clock: it keeps counting while
/// the app is in the background, which is what a billing-relevant
/// grace period has to measure.
protocol RealtimeClock: Sendable {
    var now: ContinuousClock.Instant { get }

    func sleep(for duration: Duration) async throws
}

extension ContinuousClock: RealtimeClock {
    func sleep(for duration: Duration) async throws {
        try await sleep(for: duration, tolerance: nil)
    }
}
