import os

/// One run of an operation at a time.
///
/// A second caller that arrives while a run is in progress joins it
/// instead of starting another, so a double tap on Stop cannot tear
/// the same session down twice. Callers elsewhere can `join` the run
/// to sequence behind it.
final class SingleFlight: @unchecked Sendable {
    private let pending = OSAllocatedUnfairLock<Task<Void, Never>?>(
        initialState: nil,
    )

    var isRunning: Bool {
        pending.withLock { $0 != nil }
    }

    /// Starts `work` when nothing is running and `shouldStart` agrees,
    /// otherwise joins the run in progress. Returns once that run is
    /// over; returns at once when nothing ran.
    func run(
        ifNeeded shouldStart: @Sendable () -> Bool = { true },
        _ work: @escaping @Sendable () async -> Void,
    ) async {
        let task: Task<Void, Never>? = pending.withLock { pending in
            if let pending {
                return pending
            }
            guard shouldStart() else {
                return nil
            }
            let created = Task { await work() }
            pending = created
            return created
        }
        guard let task else {
            return
        }
        await task.value
        pending.withLock { pending in
            if pending == task {
                pending = nil
            }
        }
    }

    /// Waits for the run in progress, if there is one.
    func join() async {
        await pending.withLock { $0 }?.value
    }
}
