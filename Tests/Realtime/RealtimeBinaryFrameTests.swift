import XCTest
@testable import SwiftRealtime

final class RealtimeBinaryFrameTests: XCTestCase {
    func testEncodesAndDecodesATokenPrefixedPCMFrame() {
        let payload = Data([1, 2, 3])
        let frame = RealtimeBinaryFrame.encode(
            taskToken: "task-token",
            payload: payload,
        )

        XCTAssertEqual(frame, Data("task-token|".utf8) + Data([1, 2, 3]))
        XCTAssertEqual(
            RealtimeBinaryFrame.decodePayload(
                taskToken: "task-token",
                frame: frame,
            ),
            payload,
        )
    }

    func testRejectsABinaryFrameForAnotherTaskToken() {
        let frame = RealtimeBinaryFrame.encode(
            taskToken: "other-token",
            payload: Data([1, 2, 3]),
        )

        XCTAssertNil(
            RealtimeBinaryFrame.decodePayload(
                taskToken: "task-token",
                frame: frame,
            ),
        )
    }
}
