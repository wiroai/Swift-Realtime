import Foundation
import os

protocol RealtimeSessionClient: AnyObject, Sendable {
    var isReady: Bool { get }
    var isClosed: Bool { get }

    func addEventListener(
        _ listener: @escaping @Sendable (RealtimeEvent) -> Void,
    )
    func addErrorListener(
        _ listener: @escaping @Sendable (Error) -> Void,
    )
    func addDoneListener(
        _ listener: @escaping @Sendable () -> Void,
    )
    func connect() async throws
    func sendAudio(_ pcmBytes: Data) -> Bool
    func sendSessionEnd()
    func close() async
}

typealias RealtimeSessionFactory = @Sendable (
    _ taskId: String,
    _ taskToken: String,
) -> any RealtimeSessionClient

final class RealtimeSession: RealtimeSessionClient, @unchecked Sendable {
    private typealias ReadyWaiter = CheckedContinuation<Void, Error>

    private struct State {
        var ready = false
        var closed = false
        var subscriptionSent = false
        var sessionEndSent = false
        var listeners: [@Sendable (RealtimeEvent) -> Void] = []
        var errorListeners: [@Sendable (Error) -> Void] = []
        var doneListeners: [@Sendable () -> Void] = []
        var doneNotified = false
        var readyWaiters: [ReadyWaiter] = []
        var connectTask: Task<Void, Error>?
        var closeTask: Task<Void, Never>?
    }

    /// How long a subscriber waits for `task_stream_ready` when the
    /// caller names no model-specific wait: long enough for a warm
    /// worker, short enough that a lost task is not mistaken for a
    /// slow one.
    static let defaultReadyTimeout: Duration = .seconds(15)

    /// A socket that will not acknowledge its close is already gone;
    /// the listener wait for `done` must not hang on it.
    static let defaultCloseTimeout: Duration = .seconds(3)

    private let socketClient: any RealtimeSocketClient
    private let taskId: String
    private let taskToken: String
    private let parser: RealtimeEventParser
    private let readyTimeout: Duration
    private let closeTimeout: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let logger = Logger(
        subsystem: "ai.wiro.SwiftRealtime",
        category: "RealtimeSession",
    )

    init(
        socketClient: any RealtimeSocketClient,
        taskId: String,
        taskToken: String,
        parser: RealtimeEventParser = RealtimeEventParser(),
        readyTimeout: Duration = defaultReadyTimeout,
        closeTimeout: Duration = defaultCloseTimeout,
    ) {
        self.socketClient = socketClient
        self.taskId = taskId
        self.taskToken = taskToken
        self.parser = parser
        self.readyTimeout = readyTimeout
        self.closeTimeout = closeTimeout
    }

    var isReady: Bool {
        state.withLock { $0.ready && !$0.closed }
    }

    var isClosed: Bool {
        state.withLock(\.closed)
    }

    func addEventListener(
        _ listener: @escaping @Sendable (RealtimeEvent) -> Void,
    ) {
        state.withLock { $0.listeners.append(listener) }
    }

    func addErrorListener(
        _ listener: @escaping @Sendable (Error) -> Void,
    ) {
        state.withLock { $0.errorListeners.append(listener) }
    }

    func addDoneListener(
        _ listener: @escaping @Sendable () -> Void,
    ) {
        state.withLock { $0.doneListeners.append(listener) }
    }

    func connect() async throws {
        let task = state.withLock { state -> Task<Void, Error> in
            if let existing = state.connectTask {
                return existing
            }
            let task = Task { try await self.performConnect() }
            state.connectTask = task
            return task
        }
        try await task.value
    }

    func sendAudio(_ pcmBytes: Data) -> Bool {
        guard isReady, !pcmBytes.isEmpty else {
            return false
        }
        do {
            try socketClient.sendBinary(
                RealtimeBinaryFrame.encode(
                    taskToken: taskToken,
                    payload: pcmBytes,
                ),
            )
            return true
        } catch {
            return false
        }
    }

    func sendSessionEnd() {
        Task { await self.flushSessionEnd() }
    }

    func close() async {
        let task = state.withLock { state -> Task<Void, Never> in
            if let existing = state.closeTask {
                return existing
            }
            let task = Task { await self.performClose() }
            state.closeTask = task
            return task
        }
        await task.value
    }

    private func performConnect() async throws {
        if state.withLock(\.closed) {
            throw WiroFailure.cancelled
        }

        socketClient.setHandler(
            RealtimeSocketHandler(
                onFrame: { [weak self] frame in
                    self?.handleFrame(frame)
                },
                onError: { [weak self] _ in
                    self?.handleSocketError()
                },
                onDone: { [weak self] in
                    self?.handleSocketDone()
                },
            ),
        )
        try await socketClient.connect()
        if state.withLock(\.closed) {
            await socketClient.close()
            throw WiroFailure.cancelled
        }

        try await sendSubscription()

        do {
            try await waitUntilReady()
        } catch is CancellationError {
            await close()
            throw WiroFailure.cancelled
        } catch let failure as WiroFailure {
            if failure == .streamReadyTimeout {
                await close()
            }
            throw failure
        }
    }

    private func waitUntilReady() async throws {
        if isReady {
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.awaitReady()
            }
            group.addTask {
                try await Task.sleep(for: self.readyTimeout)
                throw WiroFailure.streamReadyTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func awaitReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                state.withLock { state in
                    if state.closed {
                        continuation.resume(
                            throwing: WiroFailure.cancelled,
                        )
                        return
                    }
                    if state.ready {
                        continuation.resume()
                        return
                    }
                    state.readyWaiters.append(continuation)
                }
            }
        } onCancel: {
            let waiters = state.withLock { state -> [ReadyWaiter] in
                let waiters = state.readyWaiters
                state.readyWaiters = []
                return waiters
            }
            for waiter in waiters {
                waiter.resume(throwing: CancellationError())
            }
        }
    }

    private func performClose() async {
        let waiters = state.withLock { state -> [ReadyWaiter] in
            if state.closed {
                return []
            }
            state.closed = true
            state.ready = false
            let waiters = state.readyWaiters
            state.readyWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: WiroFailure.cancelled)
        }

        await withTimeout(closeTimeout) {
            await self.socketClient.close()
        }
        socketClient.setHandler(nil)
        notifyDone()
    }

    private func flushSessionEnd() async {
        let shouldSend = state.withLock { state -> Bool in
            if state.closed || state.sessionEndSent
                || !self.socketClient.isConnected
            {
                return false
            }
            state.sessionEndSent = true
            return true
        }
        guard shouldSend else {
            return
        }
        try? await socketClient.sendText(
            encodeJSON(
                ["type": "task_session_end", "tasktoken": taskToken],
            ),
        )
    }

    private func sendSubscription() async throws {
        let shouldSend = state.withLock { state -> Bool in
            if state.subscriptionSent {
                return false
            }
            state.subscriptionSent = true
            return true
        }
        guard shouldSend else {
            return
        }
        try await socketClient.sendText(
            encodeJSON(["type": "task_info", "tasktoken": taskToken]),
        )
    }

    private func handleFrame(_ frame: RealtimeSocketFrame) {
        if state.withLock(\.closed) {
            return
        }
        let event = normalize(parser.parse(frame))
        let listeners = state.withLock(\.listeners)
        for listener in listeners {
            listener(event)
        }

        Self.logger.debug(
            "session event \(event.wireType, privacy: .public)",
        )
        switch event {
        case .status(.streamReady):
            markReady()
        case .status(.postprocessEnded):
            Task { await self.close() }
        case .cancel:
            fail(WiroFailure.cancelled)
        case .malformed:
            fail(WiroFailure.realtimeProtocol)
        case .error, .status, .output, .binary, .unknown:
            break
        }
    }

    private func normalize(_ event: RealtimeEvent) -> RealtimeEvent {
        guard case let .binary(bytes) = event else {
            return event
        }
        if let payload = RealtimeBinaryFrame.decodePayload(
            taskToken: taskToken,
            frame: bytes,
        ) {
            return .binary(payload)
        }
        if let payload = RealtimeBinaryFrame.decodePayload(
            taskToken: taskId,
            frame: bytes,
        ) {
            return .binary(payload)
        }
        #if DEBUG
        print(
            "Malformed realtime binary frame: length=\(bytes.count)",
        )
        #endif
        return .malformed
    }

    private func markReady() {
        let waiters = state.withLock { state -> [ReadyWaiter] in
            state.ready = true
            let waiters = state.readyWaiters
            state.readyWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func handleSocketError() {
        if state.withLock(\.closed) {
            return
        }
        notifyError(WiroFailure.socketConnection)
        fail(WiroFailure.socketConnection)
    }

    private func handleSocketDone() {
        if state.withLock(\.closed) {
            return
        }
        notifyDone()
        fail(WiroFailure.socketConnection)
    }

    private func notifyError(_ error: Error) {
        let listeners = state.withLock(\.errorListeners)
        for listener in listeners {
            listener(error)
        }
    }

    private func notifyDone() {
        let listeners = state.withLock { state -> [@Sendable () -> Void] in
            if state.doneNotified {
                return []
            }
            state.doneNotified = true
            return state.doneListeners
        }
        for listener in listeners {
            listener()
        }
    }

    private func fail(_ failure: WiroFailure) {
        let waiters = state.withLock { state -> [ReadyWaiter] in
            let waiters = state.readyWaiters
            state.readyWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: failure)
        }
        Task { await self.close() }
    }

    private func encodeJSON(_ object: [String: String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object)
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }

    private func withTimeout(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async -> Void,
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }
}
