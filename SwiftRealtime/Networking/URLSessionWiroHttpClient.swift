import Foundation
import os

final class URLSessionWiroHttpClient: WiroHttpClient, @unchecked Sendable {
    /// Docs say `/Run` returns tokens immediately. A cold worker has
    /// held that HTTP call for ~100s on device, so `/Run` waits
    /// longer than Cancel/Kill.
    static let runTimeoutSeconds: TimeInterval = 120

    /// Cancel/Kill answer from a warm control plane; anything slower
    /// than this is a dead network, not a slow worker.
    static let defaultRequestTimeoutSeconds: TimeInterval = 30

    /// Whole-transfer ceiling, kept a little above `/Run`'s own wait so
    /// the session floor never cuts a slow cold start first.
    static let defaultResourceTimeoutSeconds: TimeInterval = 135

    private let session: URLSession
    private let baseURL: URL
    private let ownsSession: Bool
    private let timeoutSeconds: TimeInterval

    init(
        session: URLSession? = nil,
        baseURL: URL = URL(string: WiroEndpoints.restBaseURL)!,
        timeoutIntervalForRequest: TimeInterval =
            defaultRequestTimeoutSeconds,
        timeoutIntervalForResource: TimeInterval =
            defaultResourceTimeoutSeconds,
    ) {
        self.baseURL = baseURL
        timeoutSeconds = timeoutIntervalForRequest
        if let session {
            self.session = session
            ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Session floors every transfer; keep it above `/Run`.
            configuration.timeoutIntervalForRequest =
                Self.runTimeoutSeconds
            configuration.timeoutIntervalForResource =
                timeoutIntervalForResource
            configuration.waitsForConnectivity = false
            configuration.httpAdditionalHeaders = [
                "Content-Type": "application/json",
            ]
            // Default delegate queue. A 1-wide OperationQueue
            // deadlocks `data(for:)` against its own callback, so
            // Run never returns and Task.sleep never fires.
            self.session = URLSession(configuration: configuration)
            ownsSession = true
        }
    }

    func close() {
        guard ownsSession else {
            return
        }
        session.invalidateAndCancel()
    }

    func post(
        path: String,
        headers: [String: String],
        body: [String: Any],
        cancellation: WiroRequestCancellation? = nil,
    ) async throws -> WiroHTTPResponse {
        if cancellation?.isCancelled == true {
            throw WiroFailure.cancelled
        }

        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw WiroFailure.malformedResponse
        }

        let limit = timeout(for: path)
        var request = URLRequest(
            url: url,
            timeoutInterval: limit,
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type",
        )
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: body,
            )
        } catch {
            throw WiroFailure.malformedResponse
        }

        do {
            let (data, response) = try await perform(
                request,
                cancellation: cancellation,
            )
            guard let http = response as? HTTPURLResponse else {
                throw WiroFailure.malformedResponse
            }
            let json: Any?
            if data.isEmpty {
                json = nil
            } else {
                json = try? JSONSerialization.jsonObject(with: data)
            }
            return WiroHTTPResponse(
                statusCode: http.statusCode,
                json: json,
            )
        } catch let failure as WiroFailure {
            throw failure
        } catch {
            throw mapURLError(error)
        }
    }

    private func perform(
        _ request: URLRequest,
        cancellation: WiroRequestCancellation?,
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let finish:
                @Sendable (Result<(Data, URLResponse), Error>) -> Void =
                { result in
                    let already = finished.withLock { done -> Bool in
                        if done {
                            return true
                        }
                        done = true
                        return false
                    }
                    guard !already else {
                        return
                    }
                    switch result {
                    case let .success(value):
                        continuation.resume(returning: value)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }

            let task = session.dataTask(with: request) {
                data, response, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                guard let data, let response else {
                    finish(.failure(WiroFailure.networkUnavailable))
                    return
                }
                finish(.success((data, response)))
            }

            let watchdog = DispatchWorkItem {
                task.cancel()
                finish(.failure(WiroFailure.requestTimeout))
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + request.timeoutInterval,
                execute: watchdog,
            )

            if let cancellation {
                Task {
                    await cancellation.waitUntilCancelled()
                    watchdog.cancel()
                    task.cancel()
                    finish(.failure(WiroFailure.cancelled))
                }
            }

            task.resume()
        }
    }

    private func timeout(for path: String) -> TimeInterval {
        if path.hasPrefix("/Run/") {
            return Self.runTimeoutSeconds
        }
        return timeoutSeconds
    }

    private func mapURLError(_ error: Error) -> WiroFailure {
        let urlError = error as? URLError
        switch urlError?.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .requestTimeout
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed:
            return .networkUnavailable
        default:
            return .networkUnavailable
        }
    }
}
