import Foundation
import XCTest
@testable import SwiftRealtime

final class RealtimeSessionTests: XCTestCase {
    func testSubscribesExactlyOnceAndWaitsForStreamReadiness() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)

        let connecting = Task { try await session.connect() }
        await waitUntil { socket.sentText.count == 1 }

        XCTAssertEqual(socket.connectCalls, 1)
        XCTAssertEqual(socket.sentText.count, 1)
        let payload = try decodeJSON(socket.sentText[0])
        XCTAssertEqual(payload["type"] as? String, "task_info")
        XCTAssertEqual(payload["tasktoken"] as? String, "task-token")

        socket.emitText("{\"type\":\"task_stream_ready\"}")
        try await connecting.value
        try await session.connect()

        XCTAssertTrue(session.isReady)
        XCTAssertEqual(socket.connectCalls, 1)
        XCTAssertEqual(socket.sentText.count, 1)
        await session.close()
    }

    func testEmitsOutputAndUnknownEventsAfterReady() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        let recorder = EventRecorder()
        session.addEventListener { recorder.append($0) }

        let connecting = Task { try await session.connect() }
        await waitUntil { socket.sentText.count == 1 }
        socket.emitText("{\"type\":\"task_stream_ready\"}")
        socket.emitText(
            "{\"type\":\"task_output\",\"message\":\"TRANSCRIPT_USER:Hi\"}",
        )
        socket.emitText("{\"type\":\"task_future_event\"}")
        try await connecting.value

        XCTAssertTrue(recorder.events.contains(.output("TRANSCRIPT_USER:Hi")))
        XCTAssertTrue(
            recorder.events.contains(.unknown(wireType: "task_future_event")),
        )
        await session.close()
    }

    func testPrefixesPCMAudioWithTheTaskToken() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        try await connectReady(session, socket: socket)

        let sent = session.sendAudio(Data([1, 2, 3]))

        XCTAssertTrue(sent)
        XCTAssertEqual(
            socket.sentBinary.first,
            Data("task-token|".utf8) + Data([1, 2, 3]),
        )
        await session.close()
    }

    func testStripsAndValidatesTheTokenFromServerAudio() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        let recorder = EventRecorder()
        session.addEventListener { recorder.append($0) }
        try await connectReady(session, socket: socket)

        socket.emit(
            .binary(Data("task-token|".utf8) + Data([1, 2, 3])),
        )

        let binary = recorder.events.compactMap { event -> Data? in
            if case let .binary(data) = event {
                return data
            }
            return nil
        }
        XCTAssertEqual(binary, [Data([1, 2, 3])])
        await session.close()
    }

    func testAcceptsServerAudioPrefixedWithTheTaskID() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        let recorder = EventRecorder()
        session.addEventListener { recorder.append($0) }
        try await connectReady(session, socket: socket)

        socket.emit(
            .binary(Data("2743770|".utf8) + Data([4, 5, 6])),
        )

        let binary = recorder.events.compactMap { event -> Data? in
            if case let .binary(data) = event {
                return data
            }
            return nil
        }
        XCTAssertEqual(binary, [Data([4, 5, 6])])
        await session.close()
    }

    func testClosesIdempotentlyOnPostprocessCompletion() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        try await connectReady(session, socket: socket)

        socket.emitText("{\"type\":\"task_postprocess_end\"}")
        await waitUntil { session.isClosed }
        await session.close()

        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(socket.closeCalls, 1)
        await session.close()
    }

    func testATaskErrorLogFrameKeepsTheSessionAlive() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        let recorder = EventRecorder()
        session.addEventListener { recorder.append($0) }
        try await connectReady(session, socket: socket)

        socket.emitText(
            "{\"type\":\"task_error\",\"message\":\"private server detail\"}",
        )

        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.isClosed)
        XCTAssertTrue(
            recorder.events.contains(.error(wireType: "task_error")),
        )
        await session.close()
    }

    func testMapsServerCancellationBeforeStreamReadiness() async {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        let connecting = Task { try await session.connect() }
        await waitUntil { socket.sentText.count == 1 }

        socket.emitText("{\"type\":\"task_cancel\"}")

        await XCTAssertThrowsErrorAsync({
            try await connecting.value
        }) { error in
            XCTAssertEqual(error as? WiroFailure, .cancelled)
        }
        await waitUntil { session.isClosed }
        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(socket.closeCalls, 1)
    }

    func testSendsTaskSessionEndOnceBeforeClosing() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        try await connectReady(session, socket: socket)

        session.sendSessionEnd()
        session.sendSessionEnd()
        await waitUntil { socket.sentText.count >= 2 }
        await session.close()

        let frames = try socket.sentText.map(decodeJSON)
        let ends = frames.filter {
            ($0["type"] as? String) == "task_session_end"
        }
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(frames.last?["type"] as? String, "task_session_end")
        XCTAssertEqual(frames.last?["tasktoken"] as? String, "task-token")
    }

    func testClosesWhenStreamReadinessTimesOut() async {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(
            socket,
            readyTimeout: .milliseconds(20),
        )

        await XCTAssertThrowsErrorAsync({
            try await session.connect()
        }) { error in
            XCTAssertEqual(error as? WiroFailure, .streamReadyTimeout)
        }
        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(socket.closeCalls, 1)
    }

    func testDoesNotReconnectAfterRemoteDisconnect() async throws {
        let socket = FakeRealtimeSocketClient()
        let session = makeSession(socket)
        try await connectReady(session, socket: socket)

        socket.finish()
        await waitUntil { session.isClosed }

        try await session.connect()

        XCTAssertEqual(socket.connectCalls, 1)
        XCTAssertTrue(session.isClosed)
    }

    private func connectReady(
        _ session: RealtimeSession,
        socket: FakeRealtimeSocketClient,
    ) async throws {
        let connecting = Task { try await session.connect() }
        await waitUntil { socket.sentText.count == 1 }
        socket.emitText("{\"type\":\"task_stream_ready\"}")
        try await connecting.value
    }

    private func makeSession(
        _ socket: FakeRealtimeSocketClient,
        readyTimeout: Duration = .seconds(1),
    ) -> RealtimeSession {
        RealtimeSession(
            socketClient: socket,
            taskId: "2743770",
            taskToken: "task-token",
            readyTimeout: readyTimeout,
        )
    }

    private func decodeJSON(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}

private final class EventRecorder: @unchecked Sendable {
    private(set) var events: [RealtimeEvent] = []

    func append(_ event: RealtimeEvent) {
        events.append(event)
    }
}
