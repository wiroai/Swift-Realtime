import os

/// Bounded history of realtime protocol events, kept as a diagnostics
/// log for tests and session traces.
///
/// Only the newest `maximumEvents` entries are retained so that a long
/// running session cannot grow the history without bound. Events land
/// from the socket's receive thread and from session tasks alike, so
/// the history is read and written under one lock.
final class ProtocolEventLog: @unchecked Sendable {
    let maximumEvents: Int
    private let stored = OSAllocatedUnfairLock(initialState: [String]())

    /// The retained events, oldest first.
    var events: [String] {
        stored.withLock { $0 }
    }

    init(maximumEvents: Int = 40) {
        precondition(
            maximumEvents > 0,
            "maximumEvents must be positive",
        )
        self.maximumEvents = maximumEvents
    }

    /// Appends `event`, dropping the oldest entries past
    /// `maximumEvents`, and returns the resulting history.
    @discardableResult
    func add(_ event: String) -> [String] {
        stored.withLock { stored in
            if stored.count >= maximumEvents {
                stored = Array(stored.suffix(maximumEvents - 1))
            }
            stored.append(event)
            return stored
        }
    }

    func clear() {
        stored.withLock { $0 = [] }
    }
}
