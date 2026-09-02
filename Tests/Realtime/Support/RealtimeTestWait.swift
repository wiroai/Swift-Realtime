import XCTest

/// Polls `condition` until it holds. A condition that never holds is a
/// test failure at the call site, not a silent timeout the following
/// assertion has to catch.
func waitUntil(
    _ condition: @escaping @Sendable () -> Bool,
    attempts: Int = 100,
    file: StaticString = #filePath,
    line: UInt = #line,
) async {
    for _ in 0..<attempts {
        if condition() {
            return
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail(
        "Condition never held within \(attempts) attempts",
        file: file,
        line: line,
    )
}
