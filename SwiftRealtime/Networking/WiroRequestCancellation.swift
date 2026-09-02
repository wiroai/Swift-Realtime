import Foundation

final class WiroRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilCancelled() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
