import SwiftUI

/// The app follows the system appearance. Everything on screen is a
/// system control, so light and dark both come from the OS.
private struct AppAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(AppColors.green)
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearance())
    }
}
