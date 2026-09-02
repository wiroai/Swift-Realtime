import XCTest
@testable import SwiftRealtime

@MainActor
final class RealtimeHomeModelTests: XCTestCase {
    func testOnlyTheSelectedDestinationIsVisible() {
        let model = makeModel()

        XCTAssertTrue(model.isVisible(.conversation))
        XCTAssertFalse(model.isVisible(.transcription))
        XCTAssertFalse(model.isVisible(.speech))
    }

    func testSelectingATabHidesTheOthers() {
        let model = makeModel()

        model.select(.transcription)

        XCTAssertFalse(model.isVisible(.conversation))
        XCTAssertTrue(model.isVisible(.transcription))
        XCTAssertFalse(model.isVisible(.speech))

        model.select(.speech)

        XCTAssertFalse(model.isVisible(.conversation))
        XCTAssertFalse(model.isVisible(.transcription))
        XCTAssertTrue(model.isVisible(.speech))
    }

    func testReturningToConversationRestoresItsVisibility() {
        let model = makeModel()
        model.select(.speech)
        model.select(.conversation)

        XCTAssertTrue(model.isVisible(.conversation))
        XCTAssertFalse(model.isVisible(.transcription))
        XCTAssertFalse(model.isVisible(.speech))
    }

    func testDestinationsShareOneGuardAndAudioSession() {
        let session = FakeRealtimeAudioSession()
        let sessionGuard = RealtimeSessionGuard()
        let model = RealtimeHomeModel(
            audioSession: session,
            sessionGuard: sessionGuard,
        )

        XCTAssertTrue(model.audioSession === session)
        XCTAssertTrue(model.sessionGuard === sessionGuard)
        sessionGuard.dispose()
    }

    func testSessionOwnerMatchesTheDestination() {
        XCTAssertEqual(
            RealtimeDestination.conversation.sessionOwner,
            .conversation,
        )
        XCTAssertEqual(
            RealtimeDestination.transcription.sessionOwner,
            .transcription,
        )
        XCTAssertEqual(
            RealtimeDestination.speech.sessionOwner,
            .speech,
        )
    }

    private func makeModel() -> RealtimeHomeModel {
        RealtimeHomeModel(
            audioSession: FakeRealtimeAudioSession(),
        )
    }
}
