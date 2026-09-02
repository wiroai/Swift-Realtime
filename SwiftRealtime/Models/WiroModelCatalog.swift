/// Model parameter table from Wiro MCP `get_model_schema` on 2026-08-21.
///
/// `openbmb/voxcpm2` defaults for `cfgValue` and `inferenceSteps` come
/// from the live model page; MCP schema listed the fields without
/// defaults.
enum WiroModelCatalog {
    /// The two conversation fields the app fills in itself rather
    /// than leaving to the settings form.
    static let voiceFieldId = "voice"
    static let instructionsFieldId = "system_instructions"

    static let gptRealtimeMini = ModelDefinition(
        owner: "openai",
        slug: "gpt-realtime-mini",
        displayName: "GPT Realtime Mini",
        direction: .speechToSpeech,
        fields: [
            ModelFieldDefinition(
                id: voiceFieldId,
                label: "Voice",
                kind: .select,
                isRequired: true,
                includeInFirstPass: true,
                options: options(
                    "marin",
                    "cedar",
                    "alloy",
                    "ash",
                    "ballad",
                    "coral",
                    "echo",
                    "fable",
                    "nova",
                    "onyx",
                    "sage",
                    "shimmer",
                    "verse",
                ),
                defaultValue: "marin",
            ),
            // What the assistant is told lives in ConversationConfig,
            // since it is an application's choice rather than something
            // the schema fixes.
            ModelFieldDefinition(
                id: instructionsFieldId,
                label: "System instructions",
                kind: .textarea,
                isRequired: true,
                includeInFirstPass: true,
            ),
            ModelFieldDefinition(
                id: "transcription_model",
                label: "Transcription model",
                kind: .select,
                isRequired: false,
                includeInFirstPass: true,
                options: options(
                    "gpt-4o-mini-transcribe",
                    "gpt-4o-transcribe",
                    "whisper-1",
                ),
                defaultValue: "gpt-4o-mini-transcribe",
            ),
            ModelFieldDefinition(
                id: "input_audio_format",
                label: "Input audio format",
                kind: .select,
                isRequired: false,
                includeInFirstPass: true,
                options: options(
                    "audio/pcm",
                    "audio/pcmu",
                    "audio/pcma",
                ),
                defaultValue: "audio/pcm",
            ),
            ModelFieldDefinition(
                id: "output_audio_format",
                label: "Output audio format",
                kind: .select,
                isRequired: false,
                includeInFirstPass: true,
                options: options(
                    "audio/pcm",
                    "audio/pcmu",
                    "audio/pcma",
                ),
                defaultValue: "audio/pcm",
            ),
            ModelFieldDefinition(
                id: "input_audio_rate",
                label: "Input audio rate",
                kind: .select,
                isRequired: false,
                includeInFirstPass: true,
                options: options("24000", "8000"),
                defaultValue: "24000",
            ),
            ModelFieldDefinition(
                id: "output_audio_rate",
                label: "Output audio rate",
                kind: .select,
                isRequired: false,
                includeInFirstPass: true,
                options: options("24000", "8000"),
                defaultValue: "24000",
            ),
            ModelFieldDefinition(
                id: "turn_detection_threshold",
                label: "Turn detection threshold",
                kind: .float,
                isRequired: false,
                includeInFirstPass: true,
                defaultValue: "0.75",
            ),
            ModelFieldDefinition(
                id: "turn_detection_silence_ms",
                label: "Silence duration (ms)",
                kind: .number,
                isRequired: false,
                includeInFirstPass: true,
                defaultValue: "700",
            ),
        ],
    )

    static let voxtralMiniRealtime = ModelDefinition(
        owner: "mistralai",
        slug: "voxtral-mini-4b-realtime-2602",
        displayName: "Voxtral Mini Realtime",
        direction: .speechToText,
        fields: [
            ModelFieldDefinition(
                id: "transcriptionDelay",
                label: "Transcription delay",
                kind: .select,
                isRequired: false,
                includeInFirstPass: true,
                options: options(
                    "fastest",
                    "fast",
                    "balanced",
                    "accurate",
                ),
                defaultValue: "balanced",
            ),
        ],
    )

    static let mossTtsRealtime = ModelDefinition(
        owner: "openmoss",
        slug: "moss-tts-realtime",
        displayName: "MOSS TTS Realtime",
        direction: .textToSpeech,
        fields: [
            ModelFieldDefinition(
                id: "text",
                label: "Text",
                kind: .textarea,
                isRequired: false,
                includeInFirstPass: true,
            ),
            ModelFieldDefinition(
                id: "inputAudio",
                label: "Reference audio",
                kind: .text,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "temperature",
                label: "Temperature",
                kind: .float,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "topP",
                label: "Top P",
                kind: .float,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "topK",
                label: "Top K",
                kind: .number,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "repetitionPenalty",
                label: "Repetition penalty",
                kind: .float,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "repetitionWindow",
                label: "Repetition window",
                kind: .number,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "maxLength",
                label: "Max length",
                kind: .number,
                isRequired: false,
                includeInFirstPass: false,
            ),
        ],
        promptFieldId: "text",
    )

    static let voxcpm2 = ModelDefinition(
        owner: "openbmb",
        slug: "voxcpm2",
        displayName: "VoxCPM2",
        direction: .textToSpeech,
        fields: [
            ModelFieldDefinition(
                id: "prompt",
                label: "Prompt",
                kind: .textarea,
                isRequired: false,
                includeInFirstPass: true,
            ),
            ModelFieldDefinition(
                id: "inputAudio",
                label: "Reference audio",
                kind: .text,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "inputAudio2",
                label: "Prompt audio",
                kind: .text,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "promptAudioText",
                label: "Prompt audio text",
                kind: .textarea,
                isRequired: false,
                includeInFirstPass: false,
            ),
            ModelFieldDefinition(
                id: "cfgValue",
                label: "CFG value",
                kind: .float,
                isRequired: true,
                includeInFirstPass: true,
                defaultValue: "2.0",
            ),
            ModelFieldDefinition(
                id: "inferenceSteps",
                label: "Inference steps",
                kind: .number,
                isRequired: false,
                includeInFirstPass: true,
                defaultValue: "10",
            ),
        ],
        promptFieldId: "prompt",
    )

    static let all: [ModelDefinition] = [
        gptRealtimeMini,
        voxtralMiniRealtime,
        mossTtsRealtime,
        voxcpm2,
    ]
}

private func options(_ values: String...) -> [ModelFieldOption] {
    values.map { ModelFieldOption(value: $0) }
}
