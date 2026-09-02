import Foundation

/// Perceptual loudness of one 16-bit little-endian PCM chunk, 0...1.
///
/// RMS is mapped through a power curve so normal speech spans most of
/// the range instead of huddling near zero. Every consumer of
/// microphone or assistant levels must read this same scale.
///
/// Conversational speech at arm's length has an RMS around 0.05–0.2
/// of full scale; the gain puts that band in the middle of the range,
/// and the sub-unity exponent lifts quiet syllables without letting a
/// shout pin the meter. `PcmNoiseGate` and the barge-in thresholds
/// are tuned against this exact curve.
private let levelGain = 5.0
private let levelCurveExponent = 0.8

func pcmNormalizedLevel(_ chunk: Data) -> Double {
    let sampleCount = chunk.count / AudioConstants.bytesPerSample
    guard sampleCount > 0 else {
        return 0
    }
    var sumOfSquares = 0.0
    chunk.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for index in 0..<sampleCount {
            let sample = Double(samples[index]) / 32_768
            sumOfSquares += sample * sample
        }
    }
    let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
    return min(1, pow(rms * levelGain, levelCurveExponent))
}
