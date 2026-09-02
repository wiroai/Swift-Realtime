/// Every string the speech screen shows.
///
/// Kept in one place so the wording can be reviewed as copy rather
/// than hunted through the view tree, and so no session enum name
/// can reach the screen by accident.
enum SpeechCopy {
    static let destinationTitle = "Speech"
    static let promptHint =
        "Type or paste the text to speak. "
            + "Tap play when you are ready."
    static let connecting = "Connecting…"
    static let preparingAudio = "Preparing audio…"
    static let startingTask = "Starting the task…"
    static let connectingStream = "Almost ready…"
    static let buffering = "Buffering…"
    static let speaking = "Speaking…"
    static let finishing = "Finishing…"
    static let model = "Model"
    static let play = "Play"
    static let stop = "Stop"
    static let cancel = "Cancel"
    static let settings = "Settings"
    static let emptyDetail =
        "Write a prompt, then play it as speech."

    static func characterCount(_ count: Int) -> String {
        "\(count) characters"
    }
}

/// The wait between the tap and audible speech.
enum SpeechConnectProgress {
    static func caption(
        for state: RealtimeSessionState,
        isPlaying: Bool,
    ) -> String? {
        switch state {
        case .preparingAudio:
            SpeechCopy.preparingAudio
        case .creatingTask:
            SpeechCopy.startingTask
        case .connectingSocket:
            SpeechCopy.connecting
        case .waitingForStream:
            SpeechCopy.connectingStream
        case .streaming:
            isPlaying ? SpeechCopy.speaking : SpeechCopy.buffering
        case .stopping:
            SpeechCopy.finishing
        default:
            nil
        }
    }
}

enum SpeechFields {
    static let models: [ModelDefinition] = [
        WiroModelCatalog.mossTtsRealtime,
        WiroModelCatalog.voxcpm2,
    ]

    static func settingsFields(
        in model: ModelDefinition,
    ) -> [ModelFieldDefinition] {
        model.firstPassFields.filter { $0.id != model.promptFieldId }
    }
}
