import Foundation
import os

/// Two-stage barge-in: a loud moment ducks the assistant while its
/// audio keeps playing; only input that sustains like speech commits
/// the cut, while a noise burst just brings the volume back up. The
/// cost of a wrong suspicion is a dip, never a gap or a lost word.
///
/// The hold deadline runs on its own timer so a mute or a stalling
/// mic mid-hold still resolves, rather than waiting on the next
/// chunk.
///
/// A finger landing on the glass is the loudest thing the microphone
/// hears from a few centimetres away, and it arrives in the same
/// three-chunk burst a spoken syllable does. The screen reports each
/// touch; for `touchGrace` after one, nothing new is suspected, so
/// opening a menu mid-answer does not silence the answer.
///
/// `evaluate()` runs on the microphone's capture thread; the hold
/// deadline fires on its own task; `noteScreenTouch()` comes from
/// the main thread. All three touch the same bookkeeping, so it
/// lives behind one lock.
final class ConversationBargeIn: @unchecked Sendable {
    private struct State {
        var holdSuppressedUntil: ContinuousClock.Instant?
        var touchSuppressedUntil: ContinuousClock.Instant?
        var holdTask: Task<Void, Never>?
        var disposed = false
    }

    private let playback: ConversationPlaybackCoordinator
    private let voiceActivity: ConversationVoiceActivity
    private let onProtocolEvent: @Sendable (String) -> Void
    private let holdTimeout: Duration
    private let holdCooldown: Duration
    private let touchGrace: Duration
    private let clock: any RealtimeClock
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        playback: ConversationPlaybackCoordinator,
        voiceActivity: ConversationVoiceActivity,
        onProtocolEvent: @escaping @Sendable (String) -> Void,
        holdTimeout: Duration = .milliseconds(900),
        holdCooldown: Duration = .milliseconds(1_500),
        touchGrace: Duration = .milliseconds(400),
        clock: any RealtimeClock = ContinuousClock(),
    ) {
        self.playback = playback
        self.voiceActivity = voiceActivity
        self.onProtocolEvent = onProtocolEvent
        self.holdTimeout = holdTimeout
        self.holdCooldown = holdCooldown
        self.touchGrace = touchGrace
        self.clock = clock
    }

    /// The screen was just touched: the burst about to reach the
    /// microphone is the finger, not the speaker. A hold already in
    /// progress keeps resolving on its own evidence.
    func noteScreenTouch() {
        let until = clock.now + touchGrace
        state.withLock { state in
            if !state.disposed {
                state.touchSuppressedUntil = until
            }
        }
    }

    /// Called by the service after every microphone chunk it accepted.
    func evaluate() {
        if state.withLock(\.disposed) {
            return
        }
        if playback.isHolding {
            if voiceActivity.userInterrupting {
                commitInterruption()
            } else if !voiceActivity.hasInterruptEvidence {
                resumeHeldTurn()
            }
            return
        }
        let now = clock.now
        let (holdSuppressed, touched) = state.withLock { state in
            (
                state.holdSuppressedUntil.map { now < $0 } ?? false,
                state.touchSuppressedUntil.map { now < $0 } ?? false,
            )
        }
        if touched {
            return
        }
        if voiceActivity.userInterrupting {
            // Reached without a hold only while holds rest after a
            // false alarm; sustained speech still cuts the
            // assistant off.
            commitInterruption()
            return
        }
        if voiceActivity.userMaybeInterrupting, !holdSuppressed,
           playback.holdTurn()
        {
            onProtocolEvent("assistant_playback_held")
            startHoldDeadline()
        }
    }

    /// Cancels the hold deadline without resolving the hold; the
    /// caller is tearing the session down and the coordinator is
    /// reset with it.
    func cancelHold() {
        state.withLock { state in
            state.holdTask?.cancel()
            state.holdTask = nil
        }
    }

    func dispose() {
        state.withLock { state in
            state.disposed = true
            state.holdTask?.cancel()
            state.holdTask = nil
        }
    }

    private func commitInterruption() {
        guard playback.interruptTurn() else {
            return
        }
        cancelHold()
        voiceActivity.resetAi()
        onProtocolEvent("assistant_interrupted")
    }

    /// The suspected interruption faded the way noise does: the
    /// speaker comes back up, and holds rest for a while so the same
    /// racket cannot keep dipping the answer.
    private func resumeHeldTurn() {
        cancelHold()
        guard playback.resumeHeldTurn() else {
            return
        }
        let cooldownEnd = clock.now + holdCooldown
        state.withLock { state in
            state.holdSuppressedUntil = cooldownEnd
        }
        onProtocolEvent("assistant_playback_resumed")
    }

    private func startHoldDeadline() {
        let clock = clock
        let holdTimeout = holdTimeout
        let task = Task { [weak self] in
            try? await clock.sleep(for: holdTimeout)
            guard let self, !Task.isCancelled else {
                return
            }
            let stillHolding = self.state.withLock { state -> Bool in
                guard !state.disposed else {
                    return false
                }
                state.holdTask = nil
                return true
            }
            guard stillHolding, self.playback.isHolding else {
                return
            }
            self.resumeHeldTurn()
        }
        state.withLock { state in
            state.holdTask?.cancel()
            state.holdTask = task
        }
    }
}
