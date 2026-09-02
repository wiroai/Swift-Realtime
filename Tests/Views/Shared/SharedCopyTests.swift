import XCTest
@testable import SwiftRealtime

final class SharedCopyTests: XCTestCase {
    func testOptionTitleCapitalizesTheFirstLetter() {
        XCTAssertEqual(OptionTitle.capitalized("cedar"), "Cedar")
        XCTAssertEqual(OptionTitle.capitalized("balanced"), "Balanced")
        XCTAssertEqual(OptionTitle.capitalized(""), "")
    }

    func testClockTextIsMinutesAndPaddedSeconds() {
        XCTAssertEqual(Duration.zero.clockText, "0:00")
        XCTAssertEqual(Duration.seconds(9).clockText, "0:09")
        XCTAssertEqual(Duration.seconds(125).clockText, "2:05")
    }
}
