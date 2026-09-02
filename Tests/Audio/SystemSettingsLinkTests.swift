import UIKit
import XCTest
@testable import SwiftRealtime

final class SystemSettingsLinkTests: XCTestCase {
    func testOpensTheSystemApplicationSettingsURL() {
        XCTAssertEqual(
            SystemSettingsLink.url?.absoluteString,
            UIApplication.openSettingsURLString,
        )
    }
}
