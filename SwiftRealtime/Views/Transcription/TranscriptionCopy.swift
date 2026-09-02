/// Every string the transcription screen shows.
enum TranscriptionCopy {
    static let cancel = "Cancel"
    static let start = "Start"
    static let stop = "Stop"
    static let mute = "Mute"
    static let unmute = "Unmute"
    static let clear = "Clear"
    static let copy = "Copy"
    static let accuracy = "Accuracy"
    static let connecting = "Connecting…"
    static let connectingPermission =
        "Waiting for microphone access…"
    static let startingTask = "Starting the task…"
    static let connectingStream = "Almost ready…"
    static let finishing = "Finishing…"
    static let emptyTitle = "Transcription"
    static let emptyDetail =
        "Start from the toolbar and start speaking. "
            + "Words appear here as you talk."
}

/// The wait between the tap and the first transcribed word.
enum TranscriptionConnectProgress {
    static func caption(
        for state: RealtimeSessionState,
    ) -> String? {
        switch state {
        case .requestingPermission:
            TranscriptionCopy.connectingPermission
        case .preparingAudio:
            TranscriptionCopy.connecting
        case .creatingTask:
            TranscriptionCopy.startingTask
        case .connectingSocket:
            TranscriptionCopy.connecting
        case .waitingForStream:
            TranscriptionCopy.connectingStream
        case .stopping:
            TranscriptionCopy.finishing
        default:
            nil
        }
    }
}

enum TranscriptionFields {
    static let delayId = "transcriptionDelay"

    static func delay(
        in model: ModelDefinition,
    ) -> ModelFieldDefinition? {
        model.firstPassFields.first { $0.id == delayId }
    }

    static func displayName(_ value: String) -> String {
        guard let first = value.first else {
            return value
        }
        return String(first).uppercased() + value.dropFirst()
    }
}
