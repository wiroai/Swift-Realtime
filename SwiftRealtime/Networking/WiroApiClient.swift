import Foundation

protocol WiroApiClient: AnyObject, Sendable {
    func createCancellation() -> WiroRequestCancellation

    func runModel(
        model: ModelDefinition,
        parameters: [String: Any],
        cancellation: WiroRequestCancellation?,
    ) async throws -> WiroRunResult

    func terminateTaskBestEffort(
        taskId: String,
        taskToken: String,
    ) async
}

final class DefaultWiroApiClient: WiroApiClient, @unchecked Sendable {
    private let httpClient: any WiroHttpClient
    private let authHeaders: WiroAuthHeaders

    init(
        httpClient: any WiroHttpClient,
        authHeaders: WiroAuthHeaders,
    ) {
        self.httpClient = httpClient
        self.authHeaders = authHeaders
    }

    func createCancellation() -> WiroRequestCancellation {
        WiroRequestCancellation()
    }

    func runModel(
        model: ModelDefinition,
        parameters: [String: Any],
        cancellation: WiroRequestCancellation? = nil,
    ) async throws -> WiroRunResult {
        let response = try await httpClient.post(
            path: WiroEndpoints.runPath(
                owner: model.owner,
                model: model.slug,
            ),
            headers: authHeaders.create(),
            body: parameters,
            cancellation: cancellation,
        )

        try validateStatusCode(response.statusCode)
        guard let dto = WiroRunResponseDTO(json: response.json),
              let result = dto.result, let errors = dto.errors
        else {
            throw WiroFailure.malformedResponse
        }
        guard result else {
            throw WiroFailure.apiRejected
        }
        let taskId = dto.taskId?.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        let taskToken = dto.taskToken?.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        guard errors.isEmpty,
              let taskId, !taskId.isEmpty,
              let taskToken, !taskToken.isEmpty
        else {
            throw WiroFailure.malformedResponse
        }

        return WiroRunResult(taskId: taskId, taskToken: taskToken)
    }

    func terminateTaskBestEffort(
        taskId: String,
        taskToken: String,
    ) async {
        do {
            let response = try await httpClient.post(
                path: WiroEndpoints.taskCancelPath,
                headers: authHeaders.create(),
                body: ["taskid": taskId],
                cancellation: nil,
            )
            if isSuccessfulTaskAction(response) {
                return
            }
        } catch {
            // The task may already be running; try Kill.
        }

        do {
            _ = try await httpClient.post(
                path: WiroEndpoints.taskKillPath,
                headers: authHeaders.create(),
                body: ["socketaccesstoken": taskToken],
                cancellation: nil,
            )
        } catch {
            // Abnormal-shutdown termination is best effort.
        }
    }

    private func isSuccessfulTaskAction(
        _ response: WiroHTTPResponse,
    ) -> Bool {
        guard response.statusCode >= 200, response.statusCode < 300 else {
            return false
        }
        let object = response.json as? [String: Any]
        return object?["result"] as? Bool == true
    }

    private func validateStatusCode(_ statusCode: Int) throws {
        if statusCode >= 200, statusCode < 300 {
            return
        }
        switch statusCode {
        case 401, 403:
            throw WiroFailure.authentication
        case 429:
            throw WiroFailure.rateLimited
        default:
            throw WiroFailure.serverUnavailable
        }
    }
}

private struct WiroRunResponseDTO {
    let result: Bool?
    let errors: [Any]?
    let taskId: String?
    let taskToken: String?

    init?(json: Any?) {
        guard let object = json as? [String: Any] else {
            return nil
        }
        result = object["result"] as? Bool
        errors = object["errors"] as? [Any]
        taskId = object["taskid"] as? String
        taskToken = object["socketaccesstoken"] as? String
    }
}
