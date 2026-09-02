import XCTest
@testable import SwiftRealtime

final class WiroAuthHeadersTests: XCTestCase {
    func testCreatesAPIKeyOnlyHeaders() {
        let headers = WiroAuthHeaders(
            credentials: WiroCredentials(apiKey: "test-key"),
        ).create()

        XCTAssertEqual(
            headers,
            [WiroAuthHeaders.apiKeyHeader: "test-key"],
        )
    }

    func testCreatesDeterministicSignatureHeaders() {
        let headers = WiroAuthHeaders(
            credentials: WiroCredentials(
                apiKey: "test-key",
                apiSecret: "test-secret",
            ),
            nonceGenerator: { "1700000000" },
        ).create()

        XCTAssertEqual(
            headers[WiroAuthHeaders.apiKeyHeader],
            "test-key",
        )
        XCTAssertEqual(
            headers[WiroAuthHeaders.nonceHeader],
            "1700000000",
        )
        XCTAssertEqual(
            headers[WiroAuthHeaders.signatureHeader],
            "0e8b719d1c158c40c2b10415f96c09b794780274f5f9cbaa48d2e723ac07fc3c",
        )
    }

    func testCreatesAFreshNonceWhenTimestampsAreEqual() {
        let generator = MonotonicWiroNonceGenerator(
            microsecondsSinceEpoch: { 42 },
        )

        XCTAssertEqual(generator.call(), "42")
        XCTAssertEqual(generator.call(), "43")
    }

    func testSignerEmitsLowercaseHexadecimalOutput() {
        let signature = createWiroRequestSignature(
            apiKey: "test-key",
            apiSecret: "test-secret",
            nonce: "1700000000",
        )

        XCTAssertEqual(signature, signature.lowercased())
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(
            signature.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef")
                    .contains($0)
            },
        )
    }
}
