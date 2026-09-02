@testable import SwiftRealtime

final class FakeWiroHttpClient: WiroHttpClient, @unchecked Sendable {
    var response: WiroHTTPResponse
    var path: String?
    var headers: [String: String]?
    var body: [String: Any]?
    var cancellation: WiroRequestCancellation?
    var paths: [String] = []

    init(response: WiroHTTPResponse) {
        self.response = response
    }

    func close() {}

    func post(
        path: String,
        headers: [String: String],
        body: [String: Any],
        cancellation: WiroRequestCancellation?,
    ) async throws -> WiroHTTPResponse {
        paths.append(path)
        self.path = path
        self.headers = headers
        self.body = body
        self.cancellation = cancellation
        return response
    }
}
