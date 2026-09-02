import Foundation

extension TimeInterval {
    /// `Duration` has no bridge to `Date` arithmetic, and the session
    /// code measures playheads and grace periods against `Date`.
    init(_ duration: Duration) {
        let components = duration.components
        self = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds)
            / 1_000_000_000_000_000_000
    }
}
