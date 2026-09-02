import Foundation

struct WiroCredentials: Equatable, Hashable, Sendable {
    let apiKey: String
    let apiSecret: String?

    init(apiKey: String, apiSecret: String? = nil) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }

    var usesSignature: Bool {
        guard let apiSecret, !apiSecret.isEmpty else {
            return false
        }
        return true
    }
}
