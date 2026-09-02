import SwiftUI

enum AppTheme {
    static let preferredColorScheme = ColorScheme.light
}

private struct AppAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(AppColors.green)
            .preferredColorScheme(AppTheme.preferredColorScheme)
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearance())
    }
}
