import Foundation
import os

/// How a live session was brought to an end.
enum RealtimeSessionEnd: Equatable, Sendable {
    /// There was no open socket to end.
    case nothingToEnd
    /// The server confirmed the end before the socket closed.
    case confirmed
    /// The socket closed without the server's confirmation.
    case unconfirmed
}

/// What came of waiting for the single realtime slot.
enum RealtimeLeaseOutcome: Equatable, Sendable {
    case acquired
    /// Another feature still holds the slot after the wait.
    case busy
    /// The caller moved on while waiting; nothing is held.
    case superseded
}

/// The plumbing every screen session shares.
///
/// One operation guard, the diagnostics log, the elapsed clock, the
/// task launcher, the lease on the single realtime slot, and the
/// socket client with its end-of-session handshake. Screen services
/// own what differs — capture, playback, transcripts, recovery — and
/// lean on this for what must behave the same everywhere, so a fix to
/// how a session ends lands once.
///
/// The socket is reached from the capture thread (`sendAudio`), the
/// receive thread (terminal events) and Swift tasks, so the
/// references live behind one lock.
final class RealtimeSessionRuntime: @unchecked Sendable {
    let owner: RealtimeSessionOwner
    let terminalTimeout: Duration
    let sessionGuard: RealtimeSessionGuard
    let taskLauncher: RealtimeTaskLauncher
    let operationGuard = RealtimeOperationGuard()
    let diagnostics = ProtocolEventLog()
    let elapsedClock = SessionElapsedClock()

    private struct State {
        var lease: RealtimeSessionLease?
        var session: (any RealtimeSessionClient)?
        var terminalWait: TerminalWait?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        owner: RealtimeSessionOwner,
        apiClient: any WiroApiClient,
        sessionGuard: RealtimeSessionGuard,
        terminalTimeout: Duration,
    ) {
        self.owner = owner
        self.sessionGuard = sessionGuard
        self.terminalTimeout = terminalTimeout
        taskLauncher = RealtimeTaskLauncher(apiClient)
    }

    var session: (any RealtimeSessionClient)? {
        state.withLock(\.session)
    }

    /// True once the server has said the task is over, whether or not
    /// the socket is still open.
    var terminalReceived: Bool {
        state.withLock { $0.terminalWait?.isCompleted ?? false }
    }

    func record(_ event: String) {
        diagnostics.add(event)
    }

    /// Waits out another feature's teardown before taking the slot.
    ///
    /// Switching tabs ends the previous session, but its lease is
    /// released a beat after the tap that lands here. Waiting turns
    /// that race into a slightly longer connect instead of a busy
    /// error.
    func acquireLease(
        isStillWanted: () -> Bool,
    ) async -> RealtimeLeaseOutcome {
        let lease = await sessionGuard.acquireWhenFree(owner)
        guard isStillWanted() else {
            sessionGuard.release(lease)
            return .superseded
        }
        guard let lease else {
            return .busy
        }
        state.withLock { $0.lease = lease }
        return .acquired
    }

    func releaseLease() {
        let lease = state.withLock { state in
            let lease = state.lease
            state.lease = nil
            return lease
        }
        sessionGuard.release(lease)
    }

    /// Adopts a freshly built socket client as the live session and
    /// arms a new end-of-session wait for it.
    func attach(_ session: any RealtimeSessionClient) {
        state.withLock { state in
            state.session = session
            state.terminalWait = TerminalWait()
        }
    }

    /// The server's own word that the task is over.
    func noteTerminalEvent() {
        state.withLock(\.terminalWait)?.complete()
    }

    /// Tells the server the session is over and waits, bounded by
    /// `terminalTimeout`, for it to agree before closing the socket.
    ///
    /// The references are kept so a caller can finish its own
    /// bookkeeping against them; `clearSession` drops them.
    func endSession() async -> RealtimeSessionEnd {
        let (session, terminalWait) = state.withLock {
            ($0.session, $0.terminalWait)
        }
        guard let session, !session.isClosed else {
            return .nothingToEnd
        }
        let shouldWaitForTerminal = session.isReady
        session.sendSessionEnd()
        var confirmed = true
        if shouldWaitForTerminal,
           let terminalWait,
           !terminalWait.isCompleted
        {
            confirmed = await terminalWait.wait(timeout: terminalTimeout)
        }
        await session.close()
        return confirmed ? .confirmed : .unconfirmed
    }

    /// Lets go of the socket without telling the server anything, so
    /// the task on the other end stays alive and reconnectable.
    func dropSession() async {
        let session = state.withLock { state in
            let session = state.session
            state.session = nil
            state.terminalWait = nil
            return session
        }
        await session?.close()
    }

    func clearSession() {
        state.withLock { state in
            state.session = nil
            state.terminalWait = nil
        }
    }

    /// Publishes the running time through `onTick` for as long as
    /// `operationId` is current, counting on from `base`.
    func startElapsedTimer(
        _ operationId: Int,
        base: Duration = .zero,
        _ onTick: @escaping @Sendable (Duration) -> Void,
    ) {
        elapsedClock.start { [weak self] elapsed in
            guard let self,
                  self.operationGuard.isCurrent(operationId)
            else {
                return
            }
            onTick(base + elapsed)
        }
    }

    /// Cancels anything still in flight before the owner goes away.
    func dispose() {
        operationGuard.dispose()
        taskLauncher.cancelPendingRequest()
        elapsedClock.stop()
    }
}

/// One-shot wait for the server's end-of-session confirmation.
///
/// Completed from the socket's receive thread and awaited from a
/// stop task, so the continuation sits behind a lock.
final class TerminalWait: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var isCompleted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isCompleted: Bool {
        state.withLock(\.isCompleted)
    }

    /// Returns early, without marking completion, when the waiting
    /// task is cancelled — a timed-out stop must not pin a
    /// continuation for a confirmation that may never come.
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.isCompleted || Task.isCancelled {
                        return true
                    }
                    state.continuation = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            takeContinuation()?.resume()
        }
    }

    /// Returns false when the timeout ran out first. A non-positive
    /// timeout does not wait at all.
    func wait(timeout: Duration) async -> Bool {
        if timeout <= .zero {
            return isCompleted
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.wait()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }

    func complete() {
        state.withLock { $0.isCompleted = true }
        takeContinuation()?.resume()
    }

    private func takeContinuation() -> CheckedContinuation<Void, Never>? {
        state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
    }
}
