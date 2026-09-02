import Foundation
import os

final class URLSessionRealtimeSocketClient: RealtimeSocketClient,
    @unchecked Sendable
{
    private typealias OpenWaiter = CheckedContinuation<Void, Error>

    private struct State {
        var webSocket: URLSessionWebSocketTask?
        var handler: RealtimeSocketHandler?
        var connected = false
        var closed = false
        var receiving = false
        var handshakeComplete = false
        var openWaiters: [OpenWaiter] = []
    }

    private static let logger = Logger(
        subsystem: "ai.wiro.SwiftRealtime",
        category: "RealtimeSocket",
    )

    private let endpoint: URL
    private let connectTimeout: Duration
    private let session: URLSession
    private let ownsSession: Bool
    private let usesHandshakeDelegate: Bool
    private let sessionDelegate: WebSocketOpenDelegate
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        endpoint: URL = URL(string: WiroEndpoints.webSocketURL)!,
        connectTimeout: Duration = .seconds(10),
        session: URLSession? = nil,
    ) {
        self.endpoint = endpoint
        self.connectTimeout = connectTimeout
        let delegate = WebSocketOpenDelegate()
        sessionDelegate = delegate
        if let session {
            self.session = session
            ownsSession = false
            usesHandshakeDelegate = false
        } else {
            self.session = URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil,
            )
            ownsSession = true
            usesHandshakeDelegate = true
        }
        delegate.owner = self
    }

    var isConnected: Bool {
        state.withLock { $0.connected && !$0.closed }
    }

    func setHandler(_ handler: RealtimeSocketHandler?) {
        state.withLock { $0.handler = handler }
    }

    func connect() async throws {
        if isConnected {
            return
        }
        if state.withLock(\.closed) {
            throw WiroFailure.socketConnection
        }

        let task = session.webSocketTask(with: endpoint)
        state.withLock { state in
            state.webSocket = task
            state.handshakeComplete = false
        }
        task.resume()

        do {
            if usesHandshakeDelegate {
                try await waitUntilHandshake()
            } else {
                try await waitUntilOpen(task)
            }
            state.withLock { $0.connected = true }
            startReceiveLoop()
        } catch let failure as WiroFailure {
            await tearDownSocket()
            throw failure
        } catch {
            await tearDownSocket()
            throw WiroFailure.socketConnection
        }
    }

    func sendText(_ message: String) async throws {
        try await send(.string(message))
    }

    func sendBinary(_ bytes: Data) throws {
        try sendNow(.data(bytes))
    }

    func close() async {
        let alreadyClosed = state.withLock { state -> Bool in
            if state.closed {
                return true
            }
            state.closed = true
            state.connected = false
            return false
        }
        if alreadyClosed {
            return
        }
        failOpenWaiters(WiroFailure.cancelled)
        await tearDownSocket()
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    fileprivate func handleDidOpen() {
        let waiters = state.withLock { state -> [OpenWaiter] in
            state.handshakeComplete = true
            let waiters = state.openWaiters
            state.openWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func send(
        _ message: URLSessionWebSocketTask.Message,
    ) async throws {
        guard isConnected,
              let webSocket = state.withLock(\.webSocket)
        else {
            throw WiroFailure.socketConnection
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            webSocket.send(message) { error in
                if error != nil {
                    continuation.resume(
                        throwing: WiroFailure.socketConnection,
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendNow(
        _ message: URLSessionWebSocketTask.Message,
    ) throws {
        guard isConnected,
              let webSocket = state.withLock(\.webSocket)
        else {
            throw WiroFailure.socketConnection
        }
        webSocket.send(message) { error in
            if let error {
                let detail = error.localizedDescription
                Self.logger.error(
                    "socket send failed: \(detail, privacy: .public)",
                )
            }
        }
    }

    private func waitUntilHandshake() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.awaitHandshake()
            }
            group.addTask {
                try await Task.sleep(for: self.connectTimeout)
                throw WiroFailure.socketConnectTimeout
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                failOpenWaiters(error)
                throw error
            }
        }
    }

    private func awaitHandshake() async throws {
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
                    if state.handshakeComplete {
                        continuation.resume()
                        return
                    }
                    state.openWaiters.append(continuation)
                }
            }
        } onCancel: {
            failOpenWaiters(CancellationError())
        }
    }

    private func failOpenWaiters(_ error: Error) {
        let waiters = state.withLock { state -> [OpenWaiter] in
            let waiters = state.openWaiters
            state.openWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func waitUntilOpen(
        _ task: URLSessionWebSocketTask,
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.ping(task)
            }
            group.addTask {
                try await Task.sleep(for: self.connectTimeout)
                throw WiroFailure.socketConnectTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func ping(
        _ task: URLSessionWebSocketTask,
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startReceiveLoop() {
        let shouldStart = state.withLock { state -> Bool in
            if state.receiving || state.closed {
                return false
            }
            state.receiving = true
            return true
        }
        guard shouldStart else {
            return
        }
        receiveNext()
    }

    private func receiveNext() {
        guard let webSocket = state.withLock(\.webSocket),
              !state.withLock(\.closed)
        else {
            return
        }
        webSocket.receive { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .success(message):
                let handler = self.state.withLock(\.handler)
                switch message {
                case let .string(text):
                    Self.logger.debug(
                        "socket text \(text.prefix(80), privacy: .public)",
                    )
                    handler?.onFrame(.text(text))
                case let .data(data):
                    Self.logger.debug(
                        "socket binary \(data.count, privacy: .public) bytes",
                    )
                    handler?.onFrame(.binary(data))
                @unknown default:
                    break
                }
                self.receiveNext()
            case let .failure(error):
                self.handleReceiveFailure(error)
            }
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        let handler = state.withLock { state -> RealtimeSocketHandler? in
            state.connected = false
            state.receiving = false
            return state.closed ? nil : state.handler
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            handler?.onDone()
            return
        }
        let detail = error.localizedDescription
        Self.logger.error(
            "socket receive failed: \(detail, privacy: .public)",
        )
        handler?.onError(WiroFailure.socketConnection)
        handler?.onDone()
    }

    private func tearDownSocket() async {
        let webSocket = state.withLock { state -> URLSessionWebSocketTask? in
            let webSocket = state.webSocket
            state.webSocket = nil
            state.connected = false
            state.receiving = false
            state.handshakeComplete = false
            return webSocket
        }
        webSocket?.cancel(
            with: .goingAway,
            reason: nil,
        )
    }
}

private final class WebSocketOpenDelegate: NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    weak var owner: URLSessionRealtimeSocketClient?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?,
    ) {
        owner?.handleDidOpen()
    }
}
