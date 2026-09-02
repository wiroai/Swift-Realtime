import XCTest
@testable import SwiftRealtime

final class ConversationStageTests: XCTestCase {
    func testMapsEverySessionStateOntoAStage() {
        let expected: [RealtimeSessionState: ConversationStage] = [
            .idle: .ready,
            .requestingPermission: .connecting,
            .preparingAudio: .connecting,
            .creatingTask: .connecting,
            .connectingSocket: .connecting,
            .waitingForStream: .connecting,
            .streaming: .live,
            .stopping: .ending,
            .completed: .ready,
            .failure: .failed,
        ]

        for (state, stage) in expected {
            XCTAssertEqual(
                state.conversationStage,
                stage,
                "\(state)",
            )
        }
    }

    func testConnectingAndEndingAreTransitional() {
        XCTAssertTrue(ConversationStage.connecting.isTransitional)
        XCTAssertTrue(ConversationStage.ending.isTransitional)
        XCTAssertFalse(ConversationStage.live.isTransitional)
        XCTAssertFalse(ConversationStage.ready.isTransitional)
        XCTAssertFalse(ConversationStage.failed.isTransitional)
    }
}
