import Foundation

/// The conversation, in one place.
///
/// This is the file to edit to turn the example into a product.
/// Everything else — the transport, the audio pipeline, the screen —
/// stays as it is.
///
/// The values here win over the catalog's own defaults, which describe
/// the model rather than this app's use of it.
enum ConversationConfig {
    /// Who the assistant is and how it should behave.
    ///
    /// The two sentences about language are worth keeping whatever else
    /// is written here: they let a speaker switch languages mid-
    /// conversation and stop the model from inventing words out of
    /// background noise.
    ///
    /// The interruption sentence is worth keeping too: a short
    /// interjection heard while the assistant was mid-sentence
    /// otherwise reads to the model as a brand new question, and it
    /// answers in full — which sounds, to the person who only meant
    /// to cut in, exactly like the assistant never stopped talking.
    static let persona =
        "Respond in the language of the latest clear spoken utterance. "
            + "Allow intentional language changes. Ignore non-speech or "
            + "unclear audio instead of inferring words. If the speaker "
            + "cuts in while you are talking, stop and let them finish; "
            + "treat a short interjection as feedback on what you were "
            + "already saying, not a new question, and reply briefly "
            + "instead of restarting with a full new answer."

    /// Which voice answers. The full list lives in `WiroModelCatalog`.
    static let voice = "marin"

    /// Which Wiro model runs the conversation.
    static let model = WiroModelCatalog.gptRealtimeMini

    /// The engineering parameters, for the developer who needs them.
    ///
    /// Everything the model accepts beyond the persona and the voice —
    /// the transcription model, audio formats and rates, turn detection
    /// — is listed with its options in the catalog. A key named here
    /// replaces that catalog default when the task is created; anything
    /// left out keeps it. Keys are the catalog's field ids, values are
    /// their string form.
    ///
    /// `persona` and `voice` have their own fields above and win over
    /// entries here, so this map cannot silently contradict them.
    ///
    /// Example keys: `transcription_model`, `turn_detection_threshold`,
    /// `turn_detection_silence_ms`.
    ///
    /// `turn_detection_threshold` is how sure the model's own voice
    /// detector — which hears the same uplinked microphone audio this
    /// app sends — has to be before it calls a sound speech. The
    /// moment it does, it stops the answer it is giving and never
    /// resumes it; this is the only lever that stops the model from
    /// generating in the first place, and a client that flushes its
    /// local speaker queue cannot undo audio the server has already
    /// decided to produce. That makes the value a trade-off: low
    /// enough that a person starting to talk is heard on their first
    /// syllable, high enough that a keyboard click or a cough across
    /// the room is not. 0.35 cut the assistant off on clicks; the
    /// catalog's 0.75 makes a quiet speaker repeat themselves.
    ///
    /// `turn_detection_silence_ms` is left at the catalog default
    /// (700 ms). It is how long the uplink has to stay quiet before
    /// the model decides the speaker has finished and answers. It
    /// has no bearing on how fast an interruption lands — that is the
    /// threshold above — and shortening it only turns the pause in
    /// the middle of a long sentence into the end of the turn, so
    /// the model answers half a question and the transcript shows
    /// the sentence in pieces.
    static let parameters: [String: String] = [
        "turn_detection_threshold": "0.6",
    ]

    /// Catalog defaults, then `overrides`, then persona and voice.
    ///
    /// The named fields spread last: a stray duplicate in the map
    /// cannot silently contradict `persona` or `voice`.
    static func parameterValues(
        model: ModelDefinition = ConversationConfig.model,
        persona: String = ConversationConfig.persona,
        voice: String = ConversationConfig.voice,
        overrides: [String: String] = ConversationConfig.parameters,
    ) -> ModelParameterValues {
        var merged = overrides
        merged[WiroModelCatalog.instructionsFieldId] = persona
        merged[WiroModelCatalog.voiceFieldId] = voice
        return ModelParameterValues(
            fields: model.firstPassFields,
            overrides: merged,
        )
    }

    /// How long a conversation is held for a speaker who left the
    /// screen, before it ends itself.
    ///
    /// Zero — leave the screen and the conversation is over — because
    /// Wiro bills a realtime task by how long it stays up, not by how
    /// much is said into it. A held task is a meter running for someone
    /// who is not there. The server takes the same view and stops a
    /// task that has gone quiet on its own, so a long hold cannot be
    /// relied on anyway.
    ///
    /// Raising it buys continuity: returning within the window rejoins
    /// the same task, and the assistant still remembers the
    /// conversation instead of starting over as a stranger. Keep it
    /// well under the server's own silence timeout — currently around
    /// twenty seconds — or the hold ends in a dead task and a wasted
    /// charge.
    static let suspendGracePeriod = Duration.zero
}
