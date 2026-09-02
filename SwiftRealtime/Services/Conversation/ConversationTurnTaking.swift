import Foundation

/// A microphone chunk as it goes to the server, with the level the
/// speaker's activity is judged by.
struct ConversationMicChunk: Sendable {
    let gated: Data
    let level: Double
}

/// Who is speaking, whether the assistant should keep talking, and
/// what the microphone sends.
///
/// Bundles the voice-activity model, the playback coordinator, the
/// barge-in policy and the noise gate, which only ever change
/// together: a chunk of assistant audio moves the playhead that the
/// gate and the barge-in read, and an interruption resets all of
/// them at once. The service feeds it microphone and assistant audio
/// and acts on what it reports; it never reaches past it.
///
/// Microphone chunks arrive on the capture thread while assistant
/// audio arrives on the socket's receive thread. Each part is
/// individually thread-safe and this type holds no state of its own.
final class ConversationTurnTaking: @unchecked Sendable {
    let voiceActivity = ConversationVoiceActivity()
    private let playback: ConversationPlaybackCoordinator
    private let bargeIn: ConversationBargeIn
    private let noiseGate: PcmNoiseGate?

    init(
        player: any PcmAudioPlayer,
        noiseGate: PcmNoiseGate?,
        holdTimeout: Duration,
        holdCooldown: Duration,
        clock: any RealtimeClock = ContinuousClock(),
        onEvent: @escaping @Sendable (String) -> Void,
    ) {
        self.noiseGate = noiseGate
        playback = ConversationPlaybackCoordinator(player)
        bargeIn = ConversationBargeIn(
            playback: playback,
            voiceActivity: voiceActivity,
            onProtocolEvent: onEvent,
            holdTimeout: holdTimeout,
            holdCooldown: holdCooldown,
            clock: clock,
        )
    }

    /// True while assistant audio is queued or still playing.
    var assistantAudible: Bool {
        voiceActivity.aiAudioPending
    }

    /// Gates a microphone chunk against the room and, while the
    /// assistant is audible, against the assistant's own voice
    /// leaking back in.
    func gate(_ chunk: Data) -> ConversationMicChunk {
        guard let noiseGate else {
            return ConversationMicChunk(
                gated: chunk,
                level: pcmNormalizedLevel(chunk),
            )
        }
        let gated = noiseGate.process(
            chunk,
            assistantAudible: assistantAudible,
        )
        return ConversationMicChunk(
            gated: gated,
            level: noiseGate.lastOutputLevel,
        )
    }

    /// Counts a chunk that reached the server toward the speaker's
    /// activity, and lets the barge-in policy act on it.
    func noteSent(_ chunk: ConversationMicChunk) {
        voiceActivity.addUserChunk(chunk.gated, level: chunk.level)
        bargeIn.evaluate()
    }

    /// Routes a chunk of assistant audio to the speaker, or not, and
    /// keeps the activity model in step with what was actually queued.
    func acceptAssistantAudio(_ bytes: Data) -> PlaybackEnqueueResult {
        let outcome = playback.enqueue(bytes)
        if outcome.silencedChunk || outcome.heldChunk {
            return outcome
        }
        if outcome.flushedPreviousTurn {
            voiceActivity.resetAi()
        }
        if !outcome.droppedChunk {
            voiceActivity.addAiChunk(bytes)
        }
        return outcome
    }

    /// The server's `task_stream_end`: the turn is over once its
    /// queued tail has played.
    func markTurnFinished() {
        playback.markTurnFinished()
    }

    /// The server moved past a cut turn without ending it; whatever
    /// audio follows is a new answer. Returns false when no
    /// interruption was latched.
    func releaseInterruptedTurn() -> Bool {
        playback.releaseInterruptedTurn()
    }

    /// Cuts the assistant off on the user's explicit request. Returns
    /// false when there was nothing to cut.
    func interruptAssistant() -> Bool {
        guard assistantAudible, playback.interruptTurn() else {
            return false
        }
        bargeIn.cancelHold()
        voiceActivity.resetAi()
        return true
    }

    /// A muted microphone cannot be interrupting anyone.
    func noteMuted() {
        voiceActivity.resetUser()
    }

    /// Cancels a pending hold deadline without resolving the hold;
    /// the caller is about to `reset` with the session.
    func cancelHold() {
        bargeIn.cancelHold()
    }

    /// Forgets the turn in progress. Run whenever playback stops:
    /// stale playhead or gate state would judge the next turn wrong.
    func reset() {
        bargeIn.cancelHold()
        playback.reset()
        voiceActivity.reset()
        noiseGate?.reset()
    }

    func dispose() {
        bargeIn.dispose()
        voiceActivity.dispose()
    }
}
