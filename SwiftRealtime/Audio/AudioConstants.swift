import Foundation

/// PCM wire format from the Wiro realtime docs.
///
/// Samples are signed 16-bit little-endian on both directions of the
/// stream; changing the rate means changing it in the Run request and in
/// the local pipeline together, or the audio is garbled.
enum AudioConstants {
    static let sampleRateHz = 24_000
    static let channelCount = 1
    static let bitsPerSample = 16
    static let chunkDuration = Duration.milliseconds(20)
    static let samplesPerChunk = 480
    static let pcmBytesPerChunk = 960
    static let bytesPerSample = bitsPerSample / 8
    static let bytesPerSecond = sampleRateHz * channelCount * bytesPerSample
    static let preferredIOBufferDuration = 0.02
    static let defaultQueueCapacityInChunks = 50

    /// Wall-clock length of a PCM byte run in the wire format, which
    /// is how playback and voice-activity code turn "bytes queued"
    /// into "seconds of speech".
    static func duration(ofPcmBytes byteCount: Int) -> TimeInterval {
        Double(byteCount) / Double(bytesPerSecond)
    }
}
