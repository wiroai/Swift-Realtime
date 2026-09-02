import SwiftUI
import UIKit

/// The wiro.ai brand green, applied as the app tint.
///
/// Everything else on screen is a system control drawing system
/// colors, so this is the only color the app owns. Dark mode lifts it
/// one step so glass toolbar items keep their contrast.
enum AppColors {
    static let green = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgb: 0x4CAF76)
                : UIColor(rgb: 0x2E7D52)
        },
    )
}

extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1,
        )
    }
}
