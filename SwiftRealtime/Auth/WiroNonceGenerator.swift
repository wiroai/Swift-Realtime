import Foundation

final class MonotonicWiroNonceGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue: Int64 = 0
    private let microsecondsSinceEpoch: @Sendable () -> Int64

    init(
        microsecondsSinceEpoch: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000_000)
        },
    ) {
        self.microsecondsSinceEpoch = microsecondsSinceEpoch
    }

    func call() -> String {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = microsecondsSinceEpoch()
        lastValue = timestamp > lastValue ? timestamp : lastValue + 1
        return String(lastValue)
    }
}
