import Foundation
import os

/// Who owns the conversation at this instant, as far as the ear can tell.
enum ConversationVoicePhase: Sendable, Equatable, Hashable {
    case quiet
    case userSpeaking
    case aiSpeaking
}

/// Live voice signals for the conversation orb.
///
/// `phase` is discrete. `userLevel` and `aiLevel` are continuous and
/// silent: they are meant to be polled, so fifty audio chunks a second
/// never schedule a rebuild on their own.
///
/// Assistant audio arrives from the network far faster than it plays.
/// Every enqueued chunk extends a playhead by its own duration, and the
/// assistant counts as speaking while the playhead is in the future.
///
/// `addAiChunk`/`resetAi` run on the socket's receive thread while
/// `addUserChunk` runs on the microphone's capture thread — genuinely
/// concurrent callers. Every mutable field lives inside one lock so a
/// barge-in decision never reads a playhead half-updated by the other
/// side.
final class ConversationVoiceActivity: @unchecked Sendable {
    static let speechThreshold = 0.18
    /// Matches `PcmNoiseGate.assistantOpenLevel`: this level is read
    /// off the same gated chunk the noise gate already decided was
    /// loud enough to leave the phone, so it cannot be stricter than
    /// that bar without becoming unreachable — the level would sit
    /// stuck at the gate's own closed-chunk floor forever.
    static let interruptThreshold = 0.32
    static let interruptSustainThreshold = 0.2
    static let userHangover = Duration.milliseconds(450)
    /// Accumulated loud chunks it takes to suspect an interruption:
    /// three chunks is sixty milliseconds, fast enough that the
    /// assistant feels silenced the instant the user starts talking.
    /// Keeping this trigger-happy is safe because suspicion only
    /// pauses playback: nothing is discarded until
    /// `confirmStreakTarget` proves the sound is speech, so a noise
    /// burst costs a beat of silence rather than the rest of the
    /// answer.
    static let suspectStreakTarget = 3
    /// Accumulated loud chunks it takes to call the suspicion speech
    /// and cut the assistant's turn for good. A noise burst is a
    /// couple of loud chunks drowning in their own true silence, so
    /// the counter cannot climb this far on noise; a spoken sentence
    /// rides its syllable dips on the sustain level and crosses
    /// within about a hundred milliseconds — cutting the confirm
    /// wait shorter than that starts eating into the hold's own
    /// two-word grace period and makes noise bursts commit.
    static let confirmStreakTarget = 5

    private static let epoch = Date(timeIntervalSince1970: 0)

    private struct State {
        var aiSegments: [AiAudioSegment] = []
        var userLevelValue = 0.0
        var interruptStreak = 0
        var userActiveUntil = ConversationVoiceActivity.epoch
        var aiPlayheadUntil = ConversationVoiceActivity.epoch
        var currentPhase: ConversationVoicePhase = .quiet
        var phaseTask: Task<Void, Never>?
        var disposed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var phase: ConversationVoicePhase {
        state.withLock(\.currentPhase)
    }

    /// Smoothed microphone level, 0..1. Poll per frame; never notifies.
    var userLevel: Double {
        state.withLock(\.userLevelValue)
    }

    /// True while queued assistant audio is still playing through the
    /// speaker, which is exactly when microphone input may carry echo.
    var aiAudioPending: Bool {
        state.withLock { Date() < $0.aiPlayheadUntil }
    }

    /// True while the user has been loud over pending assistant audio
    /// just long enough to be either speech or a burst of noise.
    var userMaybeInterrupting: Bool {
        state.withLock { state in
            state.interruptStreak >= Self.suspectStreakTarget
                && Date() < state.aiPlayheadUntil
        }
    }

    /// True once loud input over pending assistant audio has sustained
    /// the way only speech does.
    var userInterrupting: Bool {
        state.withLock { state in
            state.interruptStreak >= Self.confirmStreakTarget
                && Date() < state.aiPlayheadUntil
        }
    }

    /// True while recent chunks still argue for an interruption.
    var hasInterruptEvidence: Bool {
        state.withLock { $0.interruptStreak > 0 }
    }

    /// Level of the assistant audio playing right now, 0..1.
    var aiLevel: Double {
        state.withLock { state in
            let now = Date()
            Self.pruneExpiredSegments(&state, now)
            guard let head = state.aiSegments.first else {
                return 0
            }
            return head.start > now ? 0 : head.level
        }
    }

    /// Reports one microphone chunk that was sent to the model.
    func addUserChunk(_ chunk: Data, level: Double? = nil) {
        state.withLock { state in
            guard !state.disposed else {
                return
            }
            let measured = level ?? pcmNormalizedLevel(chunk)
            let smoothing = measured > state.userLevelValue ? 0.5 : 0.2
            state.userLevelValue +=
                (measured - state.userLevelValue) * smoothing
            let now = Date()
            let aiPending = now < state.aiPlayheadUntil
            if !aiPending {
                state.interruptStreak = 0
            } else if measured >= Self.interruptThreshold {
                if state.interruptStreak < Self.confirmStreakTarget {
                    state.interruptStreak += 1
                }
            } else if measured < Self.interruptSustainThreshold,
                      state.interruptStreak > 0
            {
                state.interruptStreak -= 1
            }
            let threshold = aiPending
                ? Self.interruptThreshold
                : Self.speechThreshold
            if measured >= threshold {
                state.userActiveUntil = now.addingTimeInterval(
                    TimeInterval(Self.userHangover),
                )
            }
            Self.updatePhase(&state, now, self)
        }
    }

    /// Reports one assistant chunk accepted by the playback queue.
    func addAiChunk(_ chunk: Data) {
        state.withLock { state in
            guard !state.disposed else {
                return
            }
            let now = Date()
            Self.pruneExpiredSegments(&state, now)
            let start = state.aiPlayheadUntil > now
                ? state.aiPlayheadUntil
                : now
            let end = start.addingTimeInterval(chunkDuration(chunk))
            state.aiSegments.append(
                AiAudioSegment(
                    start: start,
                    end: end,
                    level: pcmNormalizedLevel(chunk),
                ),
            )
            state.aiPlayheadUntil = end
            Self.updatePhase(&state, now, self)
        }
    }

    /// Forgets queued assistant audio after the player flushed it.
    func resetAi() {
        state.withLock { state in
            guard !state.disposed else {
                return
            }
            state.aiSegments.removeAll()
            state.aiPlayheadUntil = Self.epoch
            Self.updatePhase(&state, Date(), self)
        }
    }

    /// Forgets microphone activity after capture was muted or stopped.
    func resetUser() {
        state.withLock { state in
            guard !state.disposed else {
                return
            }
            state.userLevelValue = 0
            state.interruptStreak = 0
            state.userActiveUntil = Self.epoch
            Self.updatePhase(&state, Date(), self)
        }
    }

    func reset() {
        state.withLock { state in
            guard !state.disposed else {
                return
            }
            state.aiSegments.removeAll()
            state.aiPlayheadUntil = Self.epoch
            state.userLevelValue = 0
            state.interruptStreak = 0
            state.userActiveUntil = Self.epoch
            Self.updatePhase(&state, Date(), self)
        }
    }

    func dispose() {
        state.withLock { state in
            state.disposed = true
            state.phaseTask?.cancel()
            state.phaseTask = nil
        }
    }

    /// The user keeps priority: interrupting the assistant should feel
    /// heard immediately.
    private static func updatePhase(
        _ state: inout State,
        _ now: Date,
        _ owner: ConversationVoiceActivity,
    ) {
        let next: ConversationVoicePhase
        if now < state.userActiveUntil {
            next = .userSpeaking
        } else if now < state.aiPlayheadUntil {
            next = .aiSpeaking
        } else {
            next = .quiet
        }
        schedulePhaseCheck(&state, now, owner)
        state.currentPhase = next
    }

    private static func schedulePhaseCheck(
        _ state: inout State,
        _ now: Date,
        _ owner: ConversationVoiceActivity,
    ) {
        state.phaseTask?.cancel()
        state.phaseTask = nil
        let boundaries = [state.userActiveUntil, state.aiPlayheadUntil]
            .filter { $0 > now }
            .sorted()
        guard let nearest = boundaries.first else {
            return
        }
        let delay = nearest.timeIntervalSince(now) + 0.02
        state.phaseTask = Task { [weak owner] in
            try? await Task.sleep(for: .seconds(delay))
            guard let owner, !Task.isCancelled else {
                return
            }
            owner.state.withLock { state in
                guard !state.disposed else {
                    return
                }
                Self.updatePhase(&state, Date(), owner)
            }
        }
    }

    private static func pruneExpiredSegments(
        _ state: inout State,
        _ now: Date,
    ) {
        while let head = state.aiSegments.first, head.end <= now {
            state.aiSegments.removeFirst()
        }
    }

    private func chunkDuration(_ chunk: Data) -> TimeInterval {
        AudioConstants.duration(ofPcmBytes: chunk.count)
    }
}

private struct AiAudioSegment {
    let start: Date
    let end: Date
    let level: Double
}
