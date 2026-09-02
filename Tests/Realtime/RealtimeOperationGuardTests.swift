import XCTest
@testable import SwiftRealtime

final class RealtimeOperationGuardTests: XCTestCase {
    func testOnlyTheNewestOperationStaysCurrent() {
        let operationGuard = RealtimeOperationGuard()
        let first = operationGuard.begin()
        XCTAssertTrue(operationGuard.isCurrent(first))

        let second = operationGuard.begin()
        XCTAssertFalse(operationGuard.isCurrent(first))
        XCTAssertTrue(operationGuard.isCurrent(second))
        XCTAssertEqual(operationGuard.current, second)
    }

    func testAnOperationIDIsNeverReused() {
        let operationGuard = RealtimeOperationGuard()
        let ids = (0..<5).map { _ in operationGuard.begin() }
        XCTAssertEqual(ids, [1, 2, 3, 4, 5])
    }

    func testDisposalInvalidatesEveryOperation() {
        let operationGuard = RealtimeOperationGuard()
        _ = operationGuard.begin()
        let pending = operationGuard.current

        operationGuard.dispose()

        XCTAssertFalse(operationGuard.isCurrent(pending))
        XCTAssertFalse(operationGuard.isCurrent(operationGuard.current))
        XCTAssertFalse(operationGuard.isCurrent(operationGuard.begin()))
    }

    func testDisposalIsReportedForCallersHoldingNoOperationID() {
        let operationGuard = RealtimeOperationGuard()
        XCTAssertFalse(operationGuard.isDisposed)
        operationGuard.dispose()
        XCTAssertTrue(operationGuard.isDisposed)
    }

    func testAnUnclaimedIDIsNotCurrentBeforeAnyOperationStarts() {
        let operationGuard = RealtimeOperationGuard()
        XCTAssertFalse(operationGuard.isCurrent(1))
        XCTAssertTrue(operationGuard.isCurrent(operationGuard.current))
    }
}
