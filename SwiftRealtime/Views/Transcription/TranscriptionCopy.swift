/// Every string the transcription screen shows.
enum TranscriptionCopy {
    static let title = "Transcription"
    static let cancel = "Cancel"
    static let start = "Start"
    static let stop = "Stop"
    static let mute = "Mute"
    static let unmute = "Unmute"
    static let clear = "Clear"
    static let copy = "Copy"
    static let more = "More"
    static let accuracy = "Accuracy"
}

enum TranscriptionFields {
    static let delayId = "transcriptionDelay"

    static func delay(
        in model: ModelDefinition,
    ) -> ModelFieldDefinition? {
        model.firstPassFields.first { $0.id == delayId }
    }
}
