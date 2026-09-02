import Foundation
import os

/// Owns the Wiro Run task behind a realtime session: the in-flight
/// request, its cancellation, and the server-side task it produces.
///
/// A task that outlives its caller keeps billing on the server, so the
/// two ways of letting go are deliberately separate: `release` forgets
/// a task that a clean session end already wound down, while
/// `terminateBestEffort` tells the server to tear it down.
final class RealtimeTaskLauncher: @unchecked Sendable {
    private struct State {
        var runResult: WiroRunResult?
        var cancellation: WiroRequestCancellation?
    }

    private let apiClient: any WiroApiClient
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ apiClient: any WiroApiClient) {
        self.apiClient = apiClient
    }

    /// The task this launcher is holding, or nil when there is none.
    ///
    /// A socket dying does not kill the task behind it, so a caller
    /// that wants to reconnect rather than start over needs the handle
    /// it was given.
    var currentRunResult: WiroRunResult? {
        state.withLock(\.runResult)
    }

    /// Creates the task, or returns `nil` when `isStillWanted` reports
    /// that the caller moved on while the request was in flight.
    ///
    /// A task that arrives too late is terminated here, so callers
    /// never have to remember to clean up after a stale request.
    func launch(
        model: ModelDefinition,
        parameters: [String: Any],
        isStillWanted: @escaping @Sendable () -> Bool,
    ) async throws -> WiroRunResult? {
        let cancellation = apiClient.createCancellation()
        state.withLock { $0.cancellation = cancellation }

        let runResult = try await apiClient.runModel(
            model: model,
            parameters: parameters,
            cancellation: cancellation,
        )
        if !isStillWanted() {
            await apiClient.terminateTaskBestEffort(
                taskId: runResult.taskId,
                taskToken: runResult.taskToken,
            )
            return nil
        }

        state.withLock {
            $0.runResult = runResult
            $0.cancellation = nil
        }
        return runResult
    }

    /// Aborts a Run request that has not produced a task yet.
    func cancelPendingRequest() {
        let cancellation = state.withLock { state -> WiroRequestCancellation? in
            let cancellation = state.cancellation
            state.cancellation = nil
            return cancellation
        }
        cancellation?.cancel()
    }

    /// Forgets the task without terminating it, for a graceful shutdown
    /// where the session end already told the server to wind down.
    func release() {
        state.withLock { $0.runResult = nil }
    }

    /// Terminates the task, for teardowns that cannot rely on a clean
    /// session end. Safe to call when there is nothing to terminate.
    func terminateBestEffort() async {
        let runResult = state.withLock { state -> WiroRunResult? in
            let runResult = state.runResult
            state.runResult = nil
            return runResult
        }
        guard let runResult else {
            return
        }
        await apiClient.terminateTaskBestEffort(
            taskId: runResult.taskId,
            taskToken: runResult.taskToken,
        )
    }
}
