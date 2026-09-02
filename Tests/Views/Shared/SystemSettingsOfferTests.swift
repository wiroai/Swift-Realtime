import XCTest
@testable import SwiftRealtime

final class SystemSettingsOfferTests: XCTestCase {
    func testAFreshDenialRaisesTheAlertOnce() {
        var offer = SystemSettingsOffer()

        offer.apply(canOpen: true)

        XCTAssertTrue(offer.canOpen)
        XCTAssertTrue(offer.showsAlert)

        offer.dismissAlert()
        XCTAssertTrue(offer.canOpen)
        XCTAssertFalse(offer.showsAlert)

        offer.apply(canOpen: true)
        XCTAssertFalse(offer.showsAlert)
    }

    func testClearingTheDenialDropsTheAlert() {
        var offer = SystemSettingsOffer()
        offer.apply(canOpen: true)
        offer.apply(canOpen: false)

        XCTAssertFalse(offer.canOpen)
        XCTAssertFalse(offer.showsAlert)
    }

    func testALaterDenialIsANewOffer() {
        var offer = SystemSettingsOffer()
        offer.apply(canOpen: true)
        offer.dismissAlert()
        offer.apply(canOpen: false)
        offer.apply(canOpen: true)

        XCTAssertTrue(offer.canOpen)
        XCTAssertTrue(offer.showsAlert)
    }

    func testCopyIsTheSharedSettingsWording() {
        XCTAssertEqual(SystemSettingsCopy.open, "Open settings")
        XCTAssertEqual(
            SystemSettingsCopy.alertTitle,
            "Microphone access",
        )
    }
}
