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
    /// `turn_detection_threshold` is lowered from the catalog default
    /// (0.75) so the model's own voice-activity detector — which
    /// hears the same uplinked microphone audio this app sends —
    /// notices a speaker starting up sooner and truncates its own
    /// answer instead of talking over them. This is the only lever
    /// that stops the model from generating in the first place; a
    /// client that only flushes its local speaker queue cannot undo
    /// audio the server has already decided to produce.
    ///
    /// `turn_detection_silence_ms` is lowered from the catalog
    /// default (700 ms) for the same reason: it is how long the
    /// model waits after the uplink goes quiet before it decides the
    /// speaker actually stopped and it may answer. Left at 700 ms, a
    /// server that is still mid-answer when the speaker cuts in
    /// keeps that long extra window before it registers the silence
    /// that follows, which reads as the assistant ignoring the
    /// interruption for the better part of a second.
    static let parameters: [String: String] = [
        "turn_detection_threshold": "0.35",
        "turn_detection_silence_ms": "350",
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
