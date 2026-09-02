import XCTest
@testable import SwiftRealtime

final class BufferedPcmAudioRecorderTests: XCTestCase {
    func testEmitsFixedTwentyMillisecondChunksInFIFOOrder() async throws {
        let source = FakePcmCaptureSource()
        let recorder = BufferedPcmAudioRecorder(source)
        let stream = try await recorder.start(.transcription)
        let received = Task {
            var chunks: [Data] = []
            for try await chunk in stream {
                chunks.append(chunk)
                if chunks.count == 2 {
                    break
                }
            }
            return chunks
        }

        var bytes = Data(
            count: AudioConstants.pcmBytesPerChunk * 2 + 80,
        )
        for index in bytes.indices {
            bytes[index] = UInt8(index % 255)
        }
        source.emit(bytes)

        let chunks = try await received.value
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(
            chunks.allSatisfy {
                $0.count == AudioConstants.pcmBytesPerChunk
            },
        )
        await recorder.dispose()
    }

    func testMuteDropsCapturedAndQueuedMicrophoneAudio() async throws {
        let source = FakePcmCaptureSource()
        let recorder = BufferedPcmAudioRecorder(source)
        let stream = try await recorder.start(.conversation)
        let received = Task {
            var chunks: [Data] = []
            for try await chunk in stream {
                chunks.append(chunk)
                if chunks.count == 1 {
                    break
                }
            }
            return chunks
        }

        recorder.setMuted(true)
        source.emit(
            Data(count: AudioConstants.pcmBytesPerChunk * 2),
        )
        await waitUntil { recorder.mutedSourceBuffers >= 1 }
        recorder.setMuted(false)
        source.emit(
            Data(
                repeating: 7,
                count: AudioConstants.pcmBytesPerChunk,
            ),
        )

        let chunks = try await received.value
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].allSatisfy { $0 == 7 })
        await recorder.dispose()
    }

    func testMapsRawCaptureErrorsToASanitizedFailure() async throws {
        let source = FakePcmCaptureSource()
        let recorder = BufferedPcmAudioRecorder(source)
        let stream = try await recorder.start(.transcription)
        let received = Task { () -> Error? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }

        source.emitError(
            NSError(
                domain: "test",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "private platform detail",
                ],
            ),
        )

        let error = await received.value
        XCTAssertEqual(error as? AudioFailure, .capture)
        XCTAssertFalse(
            String(describing: error).contains("platform"),
        )
        await recorder.dispose()
    }

    func testRepeatedStartStopAndDisposeReleaseTheSource() async throws {
        let source = FakePcmCaptureSource()
        let recorder = BufferedPcmAudioRecorder(source)

        _ = try await recorder.start(.transcription)
        await recorder.stop()
        _ = try await recorder.start(.conversation)
        await recorder.stop()
        await recorder.dispose()
        await recorder.dispose()

        XCTAssertEqual(source.startCalls, 2)
        XCTAssertEqual(source.stopCalls, 2)
        XCTAssertEqual(source.disposeCalls, 1)
    }
}
