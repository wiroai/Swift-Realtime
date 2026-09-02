enum AudioFailureCode: Sendable, Equatable, Hashable {
    case captureUnavailable
    case playbackUnavailable
    case sessionActivationTimeout
}

struct AudioFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let code: AudioFailureCode
    let message: String

    var description: String { message }

    static let capture = AudioFailure(
        code: .captureUnavailable,
        message: "Microphone capture could not be started.",
    )

    static let playback = AudioFailure(
        code: .playbackUnavailable,
        message: "Audio playback could not be started.",
    )

    static let sessionActivationTimeout = AudioFailure(
        code: .sessionActivationTimeout,
        message: "The audio session could not be activated. Try again.",
    )
}
