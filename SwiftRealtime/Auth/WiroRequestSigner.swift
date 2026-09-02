import CryptoKit
import Foundation

func createWiroRequestSignature(
    apiKey: String,
    apiSecret: String,
    nonce: String,
) -> String {
    let key = SymmetricKey(data: Data(apiKey.utf8))
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data((apiSecret + nonce).utf8),
        using: key,
    )
    return Data(mac).map { byte in
        String(format: "%02x", byte)
    }.joined()
}
