import Foundation
import os

/// What happened to a chunk of assistant audio on its way to the speaker.
///
/// The two outcomes are independent: a chunk can clear an interrupted
/// turn and still be dropped by a full queue.
struct PlaybackEnqueueResult: Equatable, Sendable {
    var flushedPreviousTurn: Bool
    var droppedChunk: Bool
    var silencedChunk: Bool
    var heldChunk: Bool

    init(
        flushedPreviousTurn: Bool,
        droppedChunk: Bool,
        silencedChunk: Bool = false,
        heldChunk: Bool = false,
    ) {
        self.flushedPreviousTurn = flushedPreviousTurn
        self.droppedChunk = droppedChunk
        self.silencedChunk = silencedChunk
        self.heldChunk = heldChunk
    }
}

/// Feeds assistant audio to the player and decides what happens to
/// audio left over from a turn the user interrupted.
///
/// A finished turn keeps playing its queued tail so speech stays
/// gapless. A suspected interruption silences the speaker while
/// keeping the retained audio; a confirmed one discards the rest.
///
/// Audio arrives on the socket's receive thread through `enqueue`
/// while a barge-in decision arrives on the microphone's capture
/// thread through `interruptTurn` — genuinely concurrent callers,
/// not just interleaved ones. Every mutable field lives inside one
/// lock so a chunk landing mid-interrupt sees a consistent turn
/// instead of racing it.
final class ConversationPlaybackCoordinator: @unchecked Sendable {
    private static let bytesPerFrame =
        AudioConstants.channelCount * AudioConstants.bytesPerSample
    private static let epoch = Date(timeIntervalSince1970: 0)

    /// How long a cut turn stays silenced without an explicit
    /// `markTurnFinished()` or `releaseInterruptedTurn()`.
    ///
    /// `task_stream_end` marks one continuous spoken turn's real end,
    /// not a sentence boundary — a story can run this whole turn for
    /// thirty seconds or more with no boundary in between. Interrupt
    /// it and every chunk that keeps arriving for it must stay
    /// silenced for as long as the model keeps talking, however long
    /// that turns out to be; the model was never told to stop, so
    /// nothing shorter would actually be a fix. This is only the
    /// backstop against a `task_stream_end` that never arrives at
    /// all — a stuck stream, not a long answer — so it is set well
    /// past any spoken turn this app would ever produce.
    private static let interruptLatchTimeout: TimeInterval = 90

    private struct State {
        var retained: [RetainedChunk] = []
        var playheadUntil = ConversationPlaybackCoordinator.epoch
        var heldAt: Date?
        var heldTurnWasFinished = false
        var previousTurnPending = false
        var turnInterrupted = false
        var interruptedAt: Date?
    }

    private let player: any PcmAudioPlayer
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Overridable only so a test can fast-forward past
    /// `interruptLatchTimeout` without an actual wait.
    var clock: () -> Date = Date.init

    init(_ player: any PcmAudioPlayer) {
        self.player = player
    }

    /// True while playback is silenced for a suspected interruption
    /// whose audio is still retained and can come back.
    var isHolding: Bool { state.withLock { $0.heldAt != nil } }

    /// Marks the assistant's turn as finished while its queued tail
    /// keeps playing, so the next turn knows it has to clear that tail.
    func markTurnFinished() {
        state.withLock { state in
            if state.turnInterrupted {
                Self.unlatchInterrupted(&state)
                return
            }
            if state.heldAt != nil {
                state.heldTurnWasFinished = true
                return
            }
            state.previousTurnPending = true
        }
    }

    /// The server has moved past the cut turn without a
    /// `task_stream_end` of its own: it transcribed the speech that
    /// interrupted it, or started dictating a new answer. Whatever
    /// audio follows is that new answer, and silencing it would lose
    /// the reply the user just asked for. Returns false when no
    /// interruption was latched.
    func releaseInterruptedTurn() -> Bool {
        state.withLock { state in
            guard state.turnInterrupted else {
                return false
            }
            Self.unlatchInterrupted(&state)
            return true
        }
    }

    /// Silences the turn on a suspected interruption while keeping
    /// its unplayed audio.
    func holdTurn() -> Bool {
        state.withLock { state in
            if state.turnInterrupted || state.heldAt != nil {
                return false
            }
            let now = Date()
            Self.pruneRetained(&state, now)
            if state.retained.isEmpty {
                return false
            }
            state.heldAt = now
            state.heldTurnWasFinished = state.previousTurnPending
            state.previousTurnPending = false
            player.flush()
            return true
        }
    }

    /// The suspicion proved to be noise: puts the held audio back on
    /// the player, trimmed to the point the hold silenced it.
    func resumeHeldTurn() -> [Data] {
        state.withLock { state in
            guard let heldAt = state.heldAt else {
                return []
            }
            state.heldAt = nil
            if state.heldTurnWasFinished {
                state.previousTurnPending = true
                state.heldTurnWasFinished = false
            }
            let chunks = state.retained
            state.retained.removeAll()
            var resumed: [Data] = []
            var start = Date()
            for chunk in chunks {
                let bytes = chunk.start < heldAt
                    ? Self.trimHeard(chunk, heldAt: heldAt)
                    : chunk.bytes
                if bytes.isEmpty {
                    continue
                }
                let end = start.addingTimeInterval(
                    Self.durationOf(bytes),
                )
                state.retained.append(
                    RetainedChunk(bytes: bytes, start: start, end: end),
                )
                start = end
                if player.tryEnqueue(bytes) {
                    resumed.append(bytes)
                }
            }
            state.playheadUntil = start
            return resumed
        }
    }

    /// Cuts the assistant off: queued, buffered or held audio is
    /// discarded, and further chunks of the same turn are dropped.
    func interruptTurn() -> Bool {
        state.withLock { state in
            if state.turnInterrupted {
                return false
            }
            if state.heldAt != nil {
                state.heldAt = nil
                if state.heldTurnWasFinished {
                    state.heldTurnWasFinished = false
                } else {
                    Self.latchInterrupted(&state, clock)
                }
                Self.discardRetained(&state)
                return true
            }
            state.previousTurnPending = false
            Self.latchInterrupted(&state, clock)
            Self.discardRetained(&state)
            player.flush()
            return true
        }
    }

    func reset() {
        state.withLock { state in
            state.previousTurnPending = false
            state.turnInterrupted = false
            state.interruptedAt = nil
            state.heldAt = nil
            state.heldTurnWasFinished = false
            Self.discardRetained(&state)
        }
    }

    func enqueue(_ bytes: Data) -> PlaybackEnqueueResult {
        state.withLock { state in
            if state.turnInterrupted {
                if let interruptedAt = state.interruptedAt,
                   clock().timeIntervalSince(interruptedAt)
                   >= Self.interruptLatchTimeout
                {
                    Self.unlatchInterrupted(&state)
                } else {
                    return PlaybackEnqueueResult(
                        flushedPreviousTurn: false,
                        droppedChunk: false,
                        silencedChunk: true,
                    )
                }
            }
            if state.heldAt != nil {
                if !state.heldTurnWasFinished {
                    Self.retainDuringHold(&state, bytes)
                    return PlaybackEnqueueResult(
                        flushedPreviousTurn: false,
                        droppedChunk: false,
                        heldChunk: true,
                    )
                }
                state.heldAt = nil
                state.heldTurnWasFinished = false
                Self.discardRetained(&state)
                return PlaybackEnqueueResult(
                    flushedPreviousTurn: true,
                    droppedChunk: !enqueueAndRetain(&state, bytes),
                )
            }
            var flushedPreviousTurn = false
            if state.previousTurnPending {
                state.previousTurnPending = false
                Self.discardRetained(&state)
                player.flush()
                flushedPreviousTurn = true
            }
            return PlaybackEnqueueResult(
                flushedPreviousTurn: flushedPreviousTurn,
                droppedChunk: !enqueueAndRetain(&state, bytes),
            )
        }
    }

    private static func latchInterrupted(
        _ state: inout State,
        _ clock: () -> Date,
    ) {
        state.turnInterrupted = true
        state.interruptedAt = clock()
    }

    /// Lifting the latch also arms a flush for the next chunk: the cut
    /// turn's flush ran while its audio was still in flight, so a
    /// straggler may have reached the sink after it. The next turn
    /// must not start behind that straggler.
    private static func unlatchInterrupted(_ state: inout State) {
        state.turnInterrupted = false
        state.interruptedAt = nil
        state.previousTurnPending = true
    }

    private func enqueueAndRetain(
        _ state: inout State,
        _ bytes: Data,
    ) -> Bool {
        let now = Date()
        Self.pruneRetained(&state, now)
        if !player.tryEnqueue(bytes) {
            return false
        }
        let start = state.playheadUntil > now ? state.playheadUntil : now
        let end = start.addingTimeInterval(Self.durationOf(bytes))
        state.retained.append(
            RetainedChunk(bytes: bytes, start: start, end: end),
        )
        state.playheadUntil = end
        return true
    }

    private static func retainDuringHold(
        _ state: inout State,
        _ bytes: Data,
    ) {
        let start = state.retained.last?.end ?? Date()
        state.retained.append(
            RetainedChunk(
                bytes: bytes,
                start: start,
                end: start.addingTimeInterval(durationOf(bytes)),
            ),
        )
    }

    /// A hold freezes pruning: the clock keeps running while the
    /// speaker is silent, and pruning against it would count silence
    /// as playback.
    private static func pruneRetained(_ state: inout State, _ now: Date) {
        if state.heldAt != nil {
            return
        }
        while let head = state.retained.first, head.end <= now {
            state.retained.removeFirst()
        }
    }

    private static func discardRetained(_ state: inout State) {
        state.retained.removeAll()
        state.playheadUntil = epoch
    }

    private static func trimHeard(
        _ chunk: RetainedChunk,
        heldAt: Date,
    ) -> Data {
        let heardMicros = heldAt.timeIntervalSince(chunk.start)
            * 1_000_000
        var offset = Int(heardMicros)
            * AudioConstants.bytesPerSecond / 1_000_000
        offset -= offset % bytesPerFrame
        if offset <= 0 {
            return chunk.bytes
        }
        if offset >= chunk.bytes.count {
            return Data()
        }
        return chunk.bytes.subdata(in: offset..<chunk.bytes.count)
    }

    private static func durationOf(_ bytes: Data) -> TimeInterval {
        AudioConstants.duration(ofPcmBytes: bytes.count)
    }
}

private struct RetainedChunk {
    let bytes: Data
    let start: Date
    let end: Date
}
