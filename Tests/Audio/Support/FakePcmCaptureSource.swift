import Foundation
import os
@testable import SwiftRealtime

final class FakePcmCaptureSource: PcmCaptureSource, @unchecked Sendable {
    private struct State {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        var startCalls = 0
        var stopCalls = 0
        var disposeCalls = 0
        var recording = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isRecording: Bool {
        state.withLock(\.recording)
    }

    var startCalls: Int {
        state.withLock(\.startCalls)
    }

    var stopCalls: Int {
        state.withLock(\.stopCalls)
    }

    var disposeCalls: Int {
        state.withLock(\.disposeCalls)
    }

    func start(
        _: PcmCaptureProfile,
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        state.withLock { state in
            state.startCalls += 1
            state.recording = true
            state.continuation = pair.continuation
        }
        return pair.stream
    }

    func stop() async {
        let shouldCount = state.withLock { state -> Bool in
            guard state.recording else {
                return false
            }
            state.recording = false
            state.stopCalls += 1
            return true
        }
        guard shouldCount else {
            return
        }
        finish()
    }

    func dispose() async {
        state.withLock { $0.disposeCalls += 1 }
        await stop()
    }

    func emit(_ bytes: Data) {
        state.withLock(\.continuation)?.yield(bytes)
    }

    func emitError(_ error: Error) {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            state.recording = false
            return continuation
        }
        continuation?.finish(throwing: error)
    }

    private func finish() {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.finish()
    }
}
