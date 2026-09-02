import Foundation

enum RealtimeBinaryFrame {
    static let separator: UInt8 = 0x7C

    static func encode(
        taskToken: String,
        payload: Data,
    ) -> Data {
        var frame = Data(taskToken.utf8)
        frame.append(separator)
        frame.append(payload)
        return frame
    }

    static func decodePayload(
        taskToken: String,
        frame: Data,
    ) -> Data? {
        let tokenBytes = Data(taskToken.utf8)
        let payloadOffset = tokenBytes.count + 1
        guard frame.count >= payloadOffset,
              frame[tokenBytes.count] == separator
        else {
            return nil
        }
        if Data(frame.prefix(tokenBytes.count)) != tokenBytes {
            return nil
        }
        return Data(frame.suffix(from: payloadOffset))
    }
}
