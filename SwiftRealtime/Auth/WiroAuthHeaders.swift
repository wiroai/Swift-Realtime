import Foundation

struct WiroAuthHeaders: Sendable {
    static let apiKeyHeader = "x-api-key"
    static let nonceHeader = "x-nonce"
    static let signatureHeader = "x-signature"

    let credentials: WiroCredentials
    private let nonceGenerator: @Sendable () -> String
    private let signer: @Sendable (String, String, String) -> String

    init(
        credentials: WiroCredentials,
        nonceGenerator: (@Sendable () -> String)? = nil,
        signer: @escaping @Sendable (
            String,
            String,
            String,
        ) -> String = createWiroRequestSignature,
    ) {
        self.credentials = credentials
        self.signer = signer
        if let nonceGenerator {
            self.nonceGenerator = nonceGenerator
        } else {
            let generator = MonotonicWiroNonceGenerator()
            self.nonceGenerator = { generator.call() }
        }
    }

    func create() -> [String: String] {
        var headers = [
            Self.apiKeyHeader: credentials.apiKey,
        ]
        guard credentials.usesSignature,
              let apiSecret = credentials.apiSecret
        else {
            return headers
        }

        let nonce = nonceGenerator()
        headers[Self.nonceHeader] = nonce
        headers[Self.signatureHeader] = signer(
            credentials.apiKey,
            apiSecret,
            nonce,
        )
        return headers
    }
}
