import XCTest
@testable import SwiftRealtime

final class WiroApiClientTests: XCTestCase {
    func testReturnsTypedTaskIdentifiersFromARunResponse() async throws {
        let httpClient = FakeWiroHttpClient(
            response: WiroHTTPResponse(
                statusCode: 200,
                json: [
                    "result": true,
                    "errors": [Any](),
                    "taskid": "2221",
                    "socketaccesstoken": "task-token",
                ],
            ),
        )
        let client = Self.makeClient(httpClient)
        let cancellation = WiroRequestCancellation()

        let result = try await client.runModel(
            model: WiroModelCatalog.gptRealtimeMini,
            parameters: ["voice": "alloy"],
            cancellation: cancellation,
        )

        XCTAssertEqual(result.taskId, "2221")
        XCTAssertEqual(result.taskToken, "task-token")
        XCTAssertEqual(httpClient.path, "/Run/openai/gpt-realtime-mini")
        XCTAssertEqual(httpClient.body?["voice"] as? String, "alloy")
        XCTAssertTrue(httpClient.cancellation === cancellation)
        XCTAssertEqual(
            httpClient.headers,
            [WiroAuthHeaders.apiKeyHeader: "api-key"],
        )
    }

    func testRejectsMalformedSuccessfulResponses() async {
        let client = Self.makeClient(
            FakeWiroHttpClient(
                response: WiroHTTPResponse(
                    statusCode: 200,
                    json: [
                        "result": true,
                        "errors": [Any](),
                        "taskid": "2221",
                    ],
                ),
            ),
        )

        await XCTAssertThrowsErrorAsync({
            try await client.runModel(
                model: WiroModelCatalog.gptRealtimeMini,
                parameters: [:],
            )
        }) { error in
            XCTAssertEqual(error as? WiroFailure, .malformedResponse)
        }
    }

    func testRedactsCredentialsAndServerErrorsFromFailures() async {
        let apiKey = "private-api-key"
        let apiSecret = "private-api-secret"
        let client = DefaultWiroApiClient(
            httpClient: FakeWiroHttpClient(
                response: WiroHTTPResponse(
                    statusCode: 200,
                    json: [
                        "result": false,
                        "errors": [
                            [
                                "message":
                                    "Rejected \(apiKey) and \(apiSecret)",
                            ],
                        ],
                        "taskid": NSNull(),
                        "socketaccesstoken": NSNull(),
                    ],
                ),
            ),
            authHeaders: WiroAuthHeaders(
                credentials: WiroCredentials(
                    apiKey: apiKey,
                    apiSecret: apiSecret,
                ),
            ),
        )

        do {
            _ = try await client.runModel(
                model: WiroModelCatalog.gptRealtimeMini,
                parameters: [:],
            )
            XCTFail("Expected WiroFailure.apiRejected.")
        } catch let failure as WiroFailure {
            let text = String(describing: failure)
            XCTAssertFalse(text.contains(apiKey))
            XCTAssertFalse(text.contains(apiSecret))
            XCTAssertFalse(text.contains("Rejected"))
            XCTAssertEqual(failure, .apiRejected)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testMapsUnauthorizedResponsesToAuthenticationFailure() async {
        let client = Self.makeClient(
            FakeWiroHttpClient(
                response: WiroHTTPResponse(
                    statusCode: 401,
                    json: [
                        "result": false,
                        "errors": [Any](),
                    ],
                ),
            ),
        )

        await XCTAssertThrowsErrorAsync({
            try await client.runModel(
                model: WiroModelCatalog.gptRealtimeMini,
                parameters: [:],
            )
        }) { error in
            XCTAssertEqual(error as? WiroFailure, .authentication)
        }
    }

    func testFallsBackFromTaskCancelToTaskKill() async {
        let httpClient = FakeWiroHttpClient(
            response: WiroHTTPResponse(
                statusCode: 409,
                json: ["result": false],
            ),
        )
        let client = Self.makeClient(httpClient)

        await client.terminateTaskBestEffort(
            taskId: "task-id",
            taskToken: "task-token",
        )

        XCTAssertEqual(httpClient.paths, ["/Task/Cancel", "/Task/Kill"])
        XCTAssertEqual(
            httpClient.body?["socketaccesstoken"] as? String,
            "task-token",
        )
    }

    func testFailureExposesAStableMachineReadableCode() {
        let failure = WiroFailure.sessionBusy

        XCTAssertEqual(failure.code, .sessionBusy)
        XCTAssertTrue(failure.diagnostics.isEmpty)
    }

    private static func makeClient(
        _ httpClient: FakeWiroHttpClient,
    ) -> DefaultWiroApiClient {
        DefaultWiroApiClient(
            httpClient: httpClient,
            authHeaders: WiroAuthHeaders(
                credentials: WiroCredentials(apiKey: "api-key"),
            ),
        )
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in },
) async {
    do {
        _ = try await expression()
        XCTFail(
            "Expected an error to be thrown.",
            file: file,
            line: line,
        )
    } catch {
        errorHandler(error)
    }
}
