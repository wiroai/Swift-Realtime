import SwiftUI

/// Light-mode palette from the wiro.ai design tokens.
///
/// Translucent tokens keep the site's percentage alpha: `0x14` is 8%,
/// `0x1A` is 10%, `0x3D` is 24%, `0xDB` is 86%.
enum AppColors {
    static let background = Color(argb: 0xFFF9_F8F5)
    static let backgroundHover = Color(argb: 0xFFF4_F1EA)
    static let backgroundWarm = Color(argb: 0xFFF2_EFE8)
    static let backgroundStone = Color(argb: 0xFFED_EAE2)
    static let surface = Color(argb: 0xFFFF_FFFF)
    static let surfaceFrost = Color(argb: 0xDBFF_FFFF)

    static let ink = Color(argb: 0xFF16_140F)
    static let inkHover = Color(argb: 0xFF2A_2820)
    static let inkSecondary = Color(argb: 0xFF3D_3A33)
    static let inkMuted = Color(argb: 0xFF70_6C62)
    static let inkDisabled = Color(argb: 0xFFA8_A49A)

    static let green = Color(argb: 0xFF2E_7D52)
    static let greenMid = Color(argb: 0xFF3A_9463)
    static let greenStrong = Color(argb: 0xFF3F_9E68)
    static let greenBright = Color(argb: 0xFF4C_AF76)
    static let greenText = Color(argb: 0xFF1E_5C38)
    static let greenContainer = Color(argb: 0xFFEAF2_ED)
    static let greenSubtle = Color(argb: 0x142E_7D52)
    static let greenBorder = Color(argb: 0x3D2E_7D52)

    static let blue = Color(argb: 0xFF3B_64B4)
    static let amber = Color(argb: 0xFFC9_9A40)
    static let amberText = Color(argb: 0xFF7A_5010)
    static let amberSubtle = Color(argb: 0x1AC9_9A40)
    static let danger = Color(argb: 0xFFC0_5050)
    static let dangerText = Color(argb: 0xFFB3_471E)
    static let dangerContainer = Color(argb: 0xFFF5_ECE7)
    static let dangerSubtle = Color(argb: 0x14B3_471E)
    static let dangerBorder = Color(argb: 0x3DB3_471E)

    static let border = Color(argb: 0x1216_140F)
    static let borderMedium = Color(argb: 0x1C16_140F)
    static let borderStrong = Color(argb: 0x3316_140F)

    static let darkSurface = Color(argb: 0xFF1E_1C16)
    static let onDark = Color(argb: 0xFFF9_F8F5)
}

extension Color {
    init(argb: UInt32) {
        let alpha = Double((argb >> 24) & 0xFF) / 255
        let red = Double((argb >> 16) & 0xFF) / 255
        let green = Double((argb >> 8) & 0xFF) / 255
        let blue = Double(argb & 0xFF) / 255
        self.init(
            red: red,
            green: green,
            blue: blue,
            opacity: alpha,
        )
    }
}
