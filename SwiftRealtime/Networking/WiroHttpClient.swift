import Foundation

struct WiroHTTPResponse: @unchecked Sendable {
    let statusCode: Int
    let json: Any?
}

protocol WiroHttpClient: AnyObject, Sendable {
    func post(
        path: String,
        headers: [String: String],
        body: [String: Any],
        cancellation: WiroRequestCancellation?,
    ) async throws -> WiroHTTPResponse

    func close()
}
