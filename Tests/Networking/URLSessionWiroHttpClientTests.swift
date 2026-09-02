import Foundation
import XCTest
@testable import SwiftRealtime

final class URLSessionWiroHttpClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.stub = nil
        super.tearDown()
    }

    func testPostsARunRequestThroughURLSession() async throws {
        let runBody = Data(
            """
            {"result":true,"errors":[],"taskid":"2221",\
            "socketaccesstoken":"task-token"}
            """.utf8,
        )
        let captured = RequestBox()
        StubURLProtocol.stub = .init(data: runBody) { request in
            captured.request = request
            captured.body = urlRequestHTTPBody(request)
        }

        let client = makeClient()
        let result = try await DefaultWiroApiClient(
            httpClient: client,
            authHeaders: WiroAuthHeaders(
                credentials: WiroCredentials(apiKey: "api-key"),
            ),
        ).runModel(
            model: WiroModelCatalog.gptRealtimeMini,
            parameters: ["voice": "alloy"],
        )

        XCTAssertEqual(result.taskId, "2221")
        XCTAssertEqual(result.taskToken, "task-token")
        XCTAssertEqual(captured.request?.httpMethod, "POST")
        XCTAssertEqual(
            captured.request?.url?.absoluteString,
            "https://api.wiro.ai/v1/Run/openai/gpt-realtime-mini",
        )
        XCTAssertEqual(
            captured.request?.value(forHTTPHeaderField: "x-api-key"),
            "api-key",
        )
        XCTAssertNil(
            captured.request?.value(forHTTPHeaderField: "x-nonce"),
        )
        let body = try XCTUnwrap(captured.body)
        let json = try JSONSerialization.jsonObject(with: body)
            as? [String: Any]
        XCTAssertEqual(json?["voice"] as? String, "alloy")
    }

    func testSendsSignatureHeadersOnARunRequest() async throws {
        let runBody = Data(
            """
            {"result":true,"errors":[],"taskid":"2221",\
            "socketaccesstoken":"task-token"}
            """.utf8,
        )
        let captured = RequestBox()
        StubURLProtocol.stub = .init(data: runBody) { request in
            captured.request = request
        }

        let credentials = WiroCredentials(
            apiKey: "test-key",
            apiSecret: "test-secret",
        )
        let client = makeClient()
        _ = try await DefaultWiroApiClient(
            httpClient: client,
            authHeaders: WiroAuthHeaders(
                credentials: credentials,
                nonceGenerator: { "1700000000" },
            ),
        ).runModel(
            model: WiroModelCatalog.gptRealtimeMini,
            parameters: [:],
        )

        XCTAssertEqual(
            captured.request?.value(forHTTPHeaderField: "x-api-key"),
            "test-key",
        )
        XCTAssertEqual(
            captured.request?.value(forHTTPHeaderField: "x-nonce"),
            "1700000000",
        )
        XCTAssertEqual(
            captured.request?.value(forHTTPHeaderField: "x-signature"),
            "0e8b719d1c158c40c2b10415f96c09b794780274f5f9cbaa48d2e723ac07fc3c",
        )
    }

    func testGivesRunALongerTimeoutThanCancel() async throws {
        let captured = RequestBox()
        StubURLProtocol.stub = .init(data: Data("{}".utf8)) { request in
            captured.request = request
        }
        let client = makeClient()

        _ = try await client.post(
            path: "/Run/openmoss/moss-tts-realtime",
            headers: [:],
            body: [:],
            cancellation: nil,
        )
        XCTAssertEqual(
            captured.request?.timeoutInterval,
            URLSessionWiroHttpClient.runTimeoutSeconds,
        )

        _ = try await client.post(
            path: WiroEndpoints.taskCancelPath,
            headers: [:],
            body: [:],
            cancellation: nil,
        )
        XCTAssertEqual(captured.request?.timeoutInterval, 30)
    }

    func testMapsURLSessionTimeoutsToRequestTimeout() async {
        StubURLProtocol.stub = .init(error: URLError(.timedOut))
        let client = makeClient()

        await XCTAssertThrowsErrorAsync({
            try await client.post(
                path: "/Run/owner/model",
                headers: [:],
                body: [:],
                cancellation: nil,
            )
        }) { error in
            XCTAssertEqual(error as? WiroFailure, .requestTimeout)
        }
    }

    func testMapsRequestCancellationToCancelledFailure() async {
        let client = makeClient()
        let cancellation = WiroRequestCancellation()
        cancellation.cancel()

        await XCTAssertThrowsErrorAsync({
            try await client.post(
                path: "/Run/owner/model",
                headers: [:],
                body: [:],
                cancellation: cancellation,
            )
        }) { error in
            XCTAssertEqual(error as? WiroFailure, .cancelled)
        }
    }

    func testRequestCancellationIsIdempotent() {
        let cancellation = WiroRequestCancellation()
        cancellation.cancel()
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
    }

    private func makeClient() -> URLSessionWiroHttpClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return URLSessionWiroHttpClient(session: session)
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    var body: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedBody
        }
        set {
            lock.lock()
            storedBody = newValue
            lock.unlock()
        }
    }
}

private func urlRequestHTTPBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data
}
