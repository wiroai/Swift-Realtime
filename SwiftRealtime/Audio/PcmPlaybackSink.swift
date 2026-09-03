import Foundation

protocol PcmPlaybackSink: AnyObject, Sendable {
    func initialize() async throws
    func play() async throws
    func feed(_ chunk: Data) async throws
    func flush() async throws
    func bufferedDuration() async -> Duration
    func setVolume(_ volume: Double) async throws
    func endOfStream() async throws
    func stop() async throws
    func dispose() async
}

protocol PcmAudioPlayer: AnyObject, Sendable {
    var isPlaying: Bool { get }
    var isEnabled: Bool { get }
    var failures: AsyncStream<AudioFailure> { get }

    func start() async throws
    func tryEnqueue(_ chunk: Data) -> Bool
    func enqueue(_ chunk: Data) async
    func flush()
    func complete() async
    func setEnabled(_ enabled: Bool) async
    /// Lowers the speaker without stopping it, and raises it back.
    /// Synchronous so a barge-in can call it from the capture thread.
    func setDucked(_ ducked: Bool)
    func stop() async
    func dispose() async
}
