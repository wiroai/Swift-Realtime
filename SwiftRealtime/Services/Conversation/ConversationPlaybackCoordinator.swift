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

    init(
        flushedPreviousTurn: Bool,
        droppedChunk: Bool,
        silencedChunk: Bool = false,
    ) {
        self.flushedPreviousTurn = flushedPreviousTurn
        self.droppedChunk = droppedChunk
        self.silencedChunk = silencedChunk
    }
}

/// Feeds assistant audio to the player and decides what happens to
/// audio left over from a turn the user interrupted.
///
/// A finished turn keeps playing its queued tail so speech stays
/// gapless. A suspected interruption ducks the speaker and lets the
/// turn keep playing underneath; a confirmed one discards the rest.
/// Nothing is taken off the player on suspicion alone, so a noise
/// burst costs a dip in volume and never a gap or a lost word.
///
/// Audio arrives on the socket's receive thread through `enqueue`
/// while a barge-in decision arrives on the microphone's capture
/// thread through `interruptTurn` — genuinely concurrent callers,
/// not just interleaved ones. Every mutable field lives inside one
/// lock so a chunk landing mid-interrupt sees a consistent turn
/// instead of racing it.
final class ConversationPlaybackCoordinator: @unchecked Sendable {
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
        var playheadUntil = ConversationPlaybackCoordinator.epoch
        var holding = false
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

    /// True while the speaker is ducked for a suspected interruption.
    var isHolding: Bool { state.withLock(\.holding) }

    /// Marks the assistant's turn as finished while its queued tail
    /// keeps playing, so the next turn knows it has to clear that tail.
    func markTurnFinished() {
        state.withLock { state in
            if state.turnInterrupted {
                Self.unlatchInterrupted(&state)
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

    /// Ducks the speaker on a suspected interruption. The turn keeps
    /// playing underneath, so nothing has to come back if the
    /// suspicion proves wrong. Refused when nothing is left to play.
    func holdTurn() -> Bool {
        state.withLock { state in
            if state.turnInterrupted || state.holding
                || Date() >= state.playheadUntil
            {
                return false
            }
            state.holding = true
            player.setDucked(true)
            return true
        }
    }

    /// The suspicion proved to be noise: the speaker comes back up.
    /// Returns false when no hold was in progress.
    func resumeHeldTurn() -> Bool {
        state.withLock { state in
            guard state.holding else {
                return false
            }
            state.holding = false
            player.setDucked(false)
            return true
        }
    }

    /// Cuts the assistant off: queued or buffered audio is discarded,
    /// and further chunks of the same turn are dropped.
    func interruptTurn() -> Bool {
        state.withLock { state in
            if state.turnInterrupted {
                return false
            }
            if state.holding {
                state.holding = false
                player.setDucked(false)
            }
            state.previousTurnPending = false
            Self.latchInterrupted(&state, clock)
            state.playheadUntil = Self.epoch
            player.flush()
            return true
        }
    }

    func reset() {
        state.withLock { state in
            if state.holding {
                state.holding = false
                player.setDucked(false)
            }
            state.previousTurnPending = false
            state.turnInterrupted = false
            state.interruptedAt = nil
            state.playheadUntil = Self.epoch
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
            var flushedPreviousTurn = false
            if state.previousTurnPending {
                state.previousTurnPending = false
                state.playheadUntil = Self.epoch
                player.flush()
                flushedPreviousTurn = true
            }
            return PlaybackEnqueueResult(
                flushedPreviousTurn: flushedPreviousTurn,
                droppedChunk: !enqueueAndAdvance(&state, bytes),
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

    /// Queues the chunk and moves the playhead past it, so the
    /// coordinator knows whether anything is still to be heard.
    private func enqueueAndAdvance(
        _ state: inout State,
        _ bytes: Data,
    ) -> Bool {
        if !player.tryEnqueue(bytes) {
            return false
        }
        let now = Date()
        let start = state.playheadUntil > now ? state.playheadUntil : now
        state.playheadUntil = start.addingTimeInterval(
            AudioConstants.duration(ofPcmBytes: bytes.count),
        )
        return true
    }
}
