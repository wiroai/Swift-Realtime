import Foundation
@testable import SwiftRealtime

final class FakeRealtimeSocketClient: RealtimeSocketClient,
    @unchecked Sendable
{
    private(set) var sentText: [String] = []
    private(set) var sentBinary: [Data] = []
    private(set) var connectCalls = 0
    private(set) var closeCalls = 0
    private var connected = false
    private var handler: RealtimeSocketHandler?

    var isConnected: Bool { connected }

    func setHandler(_ handler: RealtimeSocketHandler?) {
        self.handler = handler
    }

    func connect() async throws {
        connectCalls += 1
        connected = true
    }

    func sendText(_ message: String) async throws {
        sentText.append(message)
    }

    func sendBinary(_ bytes: Data) throws {
        sentBinary.append(bytes)
    }

    func close() async {
        guard connected else {
            return
        }
        closeCalls += 1
        connected = false
    }

    func emit(_ frame: RealtimeSocketFrame) {
        handler?.onFrame(frame)
    }

    func emitText(_ json: String) {
        emit(.text(json))
    }

    func finish() {
        connected = false
        handler?.onDone()
    }
}
