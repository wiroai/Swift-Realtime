/// Copy for the system-settings escape hatch.
///
/// Features share the wording. Each screen still owns its `.alert`
/// and toolbar item.
enum SystemSettingsCopy {
    static let open = "Open settings"
    static let alertTitle = "Microphone access"
}

/// First time a permanent microphone denial appears, the screen
/// raises an alert. Dismissing it leaves the button under the
/// failure line on the stage.
struct SystemSettingsOffer: Equatable, Sendable {
    private(set) var canOpen = false
    private(set) var showsAlert = false
    private var offered = false

    mutating func apply(canOpen: Bool) {
        let offerNow = canOpen && !offered
        offered = canOpen
        self.canOpen = canOpen
        if offerNow {
            showsAlert = true
        }
        if !canOpen {
            showsAlert = false
        }
    }

    mutating func dismissAlert() {
        showsAlert = false
    }
}
