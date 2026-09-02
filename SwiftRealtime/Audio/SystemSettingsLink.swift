import UIKit

/// App Settings URL the microphone-denial path opens.
enum SystemSettingsLink {
    static var url: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}
