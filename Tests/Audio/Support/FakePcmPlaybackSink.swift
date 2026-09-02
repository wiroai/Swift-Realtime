import Foundation
import os
@testable import SwiftRealtime

final class FakePcmPlaybackSink: PcmPlaybackSink, @unchecked Sendable {
    let failFeed: Bool
    let stalled: Bool
    let feedDelay: Duration

    private struct State {
        var fedChunks: [Data] = []
        var volumes: [Double] = []
        var initializeCalls = 0
        var playCalls = 0
        var endOfStreamCalls = 0
        var stopCalls = 0
        var flushCalls = 0
        var disposeCalls = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        failFeed: Bool = false,
        stalled: Bool = false,
        feedDelay: Duration = .zero,
    ) {
        self.failFeed = failFeed
        self.stalled = stalled
        self.feedDelay = feedDelay
    }

    var fedChunks: [Data] {
        state.withLock(\.fedChunks)
    }

    var volumes: [Double] {
        state.withLock(\.volumes)
    }

    var initializeCalls: Int {
        state.withLock(\.initializeCalls)
    }

    var playCalls: Int {
        state.withLock(\.playCalls)
    }

    var endOfStreamCalls: Int {
        state.withLock(\.endOfStreamCalls)
    }

    var stopCalls: Int {
        state.withLock(\.stopCalls)
    }

    var disposeCalls: Int {
        state.withLock(\.disposeCalls)
    }

    func initialize() async throws {
        state.withLock { $0.initializeCalls += 1 }
    }

    func play() async throws {
        state.withLock { $0.playCalls += 1 }
    }

    func feed(_ chunk: Data) async throws {
        if failFeed {
            throw NSError(
                domain: "FakePcmPlaybackSink",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "private platform failure",
                ],
            )
        }
        if feedDelay > .zero {
            try await Task.sleep(for: feedDelay)
        }
        state.withLock { $0.fedChunks.append(chunk) }
    }

    func flush() async throws {
        state.withLock { state in
            state.flushCalls += 1
            state.fedChunks.removeAll()
        }
    }

    func bufferedDuration() async -> Duration {
        stalled ? .seconds(30) : .zero
    }

    func setVolume(_ volume: Double) async throws {
        state.withLock { $0.volumes.append(volume) }
    }

    func endOfStream() async throws {
        state.withLock { $0.endOfStreamCalls += 1 }
    }

    func stop() async throws {
        state.withLock { $0.stopCalls += 1 }
    }

    func dispose() async {
        state.withLock { $0.disposeCalls += 1 }
    }
}
