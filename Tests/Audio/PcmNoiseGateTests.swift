import XCTest
@testable import SwiftRealtime

final class PcmNoiseGateTests: XCTestCase {
    func testQuietRoomAudioIsAttenuatedToAWhisper() {
        let gate = PcmNoiseGate()

        let output = gate.process(pcm(amplitude: 300))

        XCTAssertFalse(gate.isOpen)
        XCTAssertLessThan(maxAmplitude(output), 30)
        XCTAssertGreaterThan(maxAmplitude(output), 0)
    }

    func testNearFieldSpeechOpensTheGateAndPassesUntouched() {
        let gate = PcmNoiseGate()
        let input = pcm(amplitude: 15_000)

        let output = gate.process(input)

        XCTAssertEqual(output, input)
        XCTAssertTrue(gate.isOpen)
    }

    func testTheDipBetweenTwoWordsStaysInsideTheHangover() {
        let gate = PcmNoiseGate()
        _ = gate.process(pcm(amplitude: 15_000))
        let dip = pcm(amplitude: 900)

        let output = gate.process(dip)

        XCTAssertEqual(output, dip)
    }

    func testHangoverLowersTheBarWithoutRemovingIt() {
        let gate = PcmNoiseGate()
        _ = gate.process(pcm(amplitude: 15_000))

        let hum = gate.process(pcm(amplitude: 200))

        XCTAssertLessThan(maxAmplitude(hum), 30)
    }

    func testASteadyHumIsRecognisedAndLearnedInSeconds() {
        let gate = PcmNoiseGate(hangover: .zero)
        let hum = pcm(amplitude: 1_500)

        XCTAssertEqual(gate.process(hum), hum)
        XCTAssertFalse(gate.hearsHum)

        for _ in 0..<50 {
            _ = gate.process(hum)
        }
        XCTAssertTrue(gate.hearsHum)

        for _ in 0..<150 {
            _ = gate.process(hum)
        }
        XCTAssertLessThan(maxAmplitude(gate.process(hum)), 150)

        let speech = pcm(amplitude: 15_000)
        XCTAssertEqual(gate.process(speech), speech)
    }

    func testALongSentenceIsNeverMistakenForAMachine() {
        let gate = PcmNoiseGate()
        let syllables: [Int16] = [
            14_000, 16_000, 9_000, 15_000, 6_000, 13_000, 800, 11_000,
        ]

        for index in 0..<500 {
            _ = gate.process(
                pcm(amplitude: syllables[index % syllables.count]),
            )
            XCTAssertFalse(gate.hearsHum, "chunk \(index)")
        }

        let loud = pcm(amplitude: 15_000)
        XCTAssertEqual(gate.process(loud), loud)
    }

    func testTheHumTestReadsShapeNotVolume() {
        let loudHum = PcmNoiseGate(hangover: .zero)
        let quietSpeech = PcmNoiseGate(hangover: .zero)
        let syllables: [Int16] = [
            1_400, 1_600, 900, 1_500, 600, 1_300, 80, 1_100,
        ]

        for index in 0..<100 {
            _ = loudHum.process(pcm(amplitude: 14_000))
            _ = quietSpeech.process(
                pcm(amplitude: syllables[index % 8]),
            )
        }

        XCTAssertTrue(loudHum.hearsHum)
        XCTAssertFalse(quietSpeech.hearsHum)
    }

    func testATelevisionBecomesTheLearnedFloor() {
        let gate = PcmNoiseGate(hangover: .zero)

        for _ in 0..<2_000 {
            _ = gate.process(pcm(amplitude: 2_500))
        }

        XCTAssertGreaterThan(gate.ambientFloor, 0.1)
        let television = gate.process(pcm(amplitude: 2_500))
        XCTAssertLessThan(maxAmplitude(television), 200)

        let speech = pcm(amplitude: 18_000)
        XCTAssertEqual(gate.process(speech), speech)
    }

    func testAssistantPlaybackRaisesTheBarSoEchoStaysQuiet() {
        let gate = PcmNoiseGate()
        let echo = pcm(amplitude: 1_000)

        let leaked = gate.process(echo, assistantAudible: true)

        XCTAssertFalse(gate.isOpen)
        XCTAssertLessThan(maxAmplitude(leaked), 200)

        let speech = pcm(amplitude: 15_000)
        XCTAssertEqual(
            gate.process(speech, assistantAudible: true),
            speech,
        )
        XCTAssertTrue(gate.isOpen)
    }

    func testResetForgetsTheLearnedRoom() {
        let gate = PcmNoiseGate()
        for _ in 0..<2_000 {
            _ = gate.process(pcm(amplitude: 2_500))
        }
        XCTAssertGreaterThan(gate.ambientFloor, 0.1)

        gate.reset()

        XCTAssertEqual(gate.ambientFloor, 0)
        XCTAssertFalse(gate.isOpen)
    }
}

private func pcm(amplitude: Int16, samples: Int = 480) -> Data {
    var data = Data(count: samples * 2)
    data.withUnsafeMutableBytes { raw in
        let buffer = raw.bindMemory(to: Int16.self)
        for index in 0..<samples {
            buffer[index] = amplitude
        }
    }
    return data
}

private func maxAmplitude(_ chunk: Data) -> Int {
    var maxValue = 0
    chunk.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for sample in samples {
            maxValue = max(maxValue, Int(abs(sample)))
        }
    }
    return maxValue
}
