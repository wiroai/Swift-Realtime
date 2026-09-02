import Foundation

/// The Wiro stack every realtime feature stands up the same way.
///
/// One HTTP client, the signed API client on top of it, and a session
/// factory whose ready-wait outlives the model's cold start. Features
/// differ only in that wait — the socket replays nothing to a
/// subscriber that arrives after an event fired, so the ready timeout
/// is sized per model rather than shared.
///
/// Owns the HTTP client it creates; `close` releases it.
final class RealtimeSessionDependencies: @unchecked Sendable {
    private let httpClient: any WiroHttpClient
    let apiClient: any WiroApiClient
    private let readyTimeout: Duration

    convenience init(
        credentials: WiroCredentials,
        readyTimeout: Duration,
    ) {
        let httpClient = URLSessionWiroHttpClient()
        self.init(
            httpClient: httpClient,
            apiClient: DefaultWiroApiClient(
                httpClient: httpClient,
                authHeaders: WiroAuthHeaders(credentials: credentials),
            ),
            readyTimeout: readyTimeout,
        )
    }

    init(
        httpClient: any WiroHttpClient,
        apiClient: any WiroApiClient,
        readyTimeout: Duration,
    ) {
        self.httpClient = httpClient
        self.apiClient = apiClient
        self.readyTimeout = readyTimeout
    }

    func createSession(
        taskId: String,
        taskToken: String,
    ) -> RealtimeSession {
        RealtimeSession(
            socketClient: URLSessionRealtimeSocketClient(),
            taskId: taskId,
            taskToken: taskToken,
            readyTimeout: readyTimeout,
        )
    }

    func close() {
        httpClient.close()
    }
}
