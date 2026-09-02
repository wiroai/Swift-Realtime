import Foundation

struct RealtimeEventParser: Sendable {
    func parse(_ frame: RealtimeSocketFrame) -> RealtimeEvent {
        switch frame {
        case let .binary(data):
            return .binary(data)
        case let .text(text):
            return parseJSON(text)
        }
    }

    private func parseJSON(_ frame: String) -> RealtimeEvent {
        guard let data = frame.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data)
        else {
            logMalformed("invalid_json")
            return .malformed
        }
        guard let object = decoded as? [String: Any] else {
            logMalformed(
                "invalid_json_shape",
                metadata: [
                    "runtimeType": String(describing: type(of: decoded)),
                ],
            )
            return .malformed
        }

        guard let wireType = object["type"] as? String,
              !wireType.isEmpty
        else {
            logMalformed(
                "missing_type",
                metadata: ["keys": Array(object.keys)],
            )
            return .malformed
        }
        if wireType == "task_output" {
            guard let message = object["message"] as? String else {
                logMalformed(
                    "invalid_task_output",
                    metadata: [
                        "messageType": String(
                            describing: Swift.type(of: object["message"]),
                        ),
                    ],
                )
                return .malformed
            }
            return .output(message)
        }
        if wireType == "task_error" || wireType == "task_error_full" {
            logTaskError(wireType, payload: object)
            return .error(wireType: wireType)
        }
        if wireType == "task_cancel" {
            return .cancel
        }
        if let known = RealtimeEventType(wireName: wireType) {
            return .status(known)
        }
        return .unknown(wireType: wireType)
    }

    private func logMalformed(
        _ reason: String,
        metadata: [String: Any] = [:],
    ) {
        #if DEBUG
        print(
            "Malformed realtime frame: reason=\(reason) "
                + "metadata=\(metadata)",
        )
        #endif
    }

    /// Debug console only: the payload is never retained on the event.
    private func logTaskError(
        _ type: String,
        payload: [String: Any],
    ) {
        #if DEBUG
        let keys = ["message", "error", "detail", "description", "code"]
        var detail: [String: Any] = [:]
        for key in keys {
            if let value = payload[key] {
                detail[key] = value
            }
        }
        print(
            "Realtime \(type) payload: "
                + "\(detail.isEmpty ? payload : detail)",
        )
        #endif
    }
}
