import Foundation

enum RealtimeSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

struct RealtimeSocketHandler: Sendable {
    var onFrame: @Sendable (RealtimeSocketFrame) -> Void
    var onError: @Sendable (Error) -> Void
    var onDone: @Sendable () -> Void
}

protocol RealtimeSocketClient: AnyObject, Sendable {
    var isConnected: Bool { get }

    func connect() async throws
    func sendText(_ message: String) async throws
    func sendBinary(_ bytes: Data) throws
    func close() async
    func setHandler(_ handler: RealtimeSocketHandler?)
}
