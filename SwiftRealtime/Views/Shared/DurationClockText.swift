extension Duration {
    /// `m:ss` for the live session clock in the navigation subtitle.
    var clockText: String {
        let seconds = Int(components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
