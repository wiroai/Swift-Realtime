import Foundation

enum PcmCaptureProfile: Sendable {
    case conversation
    case transcription
}

protocol PcmCaptureSource: AnyObject, Sendable {
    var isRecording: Bool { get }

    func start(
        _ profile: PcmCaptureProfile,
    ) async throws -> AsyncThrowingStream<Data, Error>
    func stop() async
    func dispose() async
}

protocol PcmAudioRecorder: AnyObject, Sendable {
    var isRecording: Bool { get }
    var isMuted: Bool { get }

    func start(
        _ profile: PcmCaptureProfile,
    ) async throws -> AsyncThrowingStream<Data, Error>
    func setMuted(_ muted: Bool)
    func stop() async
    func dispose() async
}
