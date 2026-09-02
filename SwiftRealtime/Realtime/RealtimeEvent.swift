import Foundation

enum RealtimeEventType: String, Sendable, Equatable, Hashable {
    case queue = "task_queue"
    case accepted = "task_accept"
    case preprocessStarted = "task_preprocess_start"
    case preprocessEnded = "task_preprocess_end"
    case assigned = "task_assign"
    case started = "task_start"
    case outputFull = "task_output_full"
    case ended = "task_end"
    case postprocessStarted = "task_postprocess_start"
    case postprocessEnded = "task_postprocess_end"
    case streamReady = "task_stream_ready"
    case streamEnded = "task_stream_end"
    case cost = "task_cost"

    var wireName: String { rawValue }

    init?(wireName: String) {
        self.init(rawValue: wireName)
    }
}

enum RealtimeEvent: Equatable, Sendable, CustomStringConvertible {
    case status(RealtimeEventType)
    case output(String)
    case error(wireType: String)
    case cancel
    case binary(Data)
    case unknown(wireType: String)
    case malformed

    var wireType: String {
        switch self {
        case let .status(type):
            return type.wireName
        case .output:
            return "task_output"
        case let .error(wireType):
            return wireType
        case .cancel:
            return "task_cancel"
        case .binary:
            return "binary"
        case let .unknown(wireType):
            return wireType
        case .malformed:
            return "malformed"
        }
    }

    var description: String {
        switch self {
        case let .status(type):
            return "status(\(type.wireName))"
        case let .output(message):
            return "output(\(message))"
        case let .error(wireType):
            return "error(\(wireType))"
        case .cancel:
            return "cancel"
        case let .binary(data):
            return "binary(\(data.count))"
        case let .unknown(wireType):
            return "unknown(\(wireType))"
        case .malformed:
            return "malformed"
        }
    }
}
