import XCTest
@testable import FlexTimer
import KaltoeCore

final class LoginWindowTests: XCTestCase {
    func testUserIdHashDecoding() {
        let raw = #"{"customerIdHash":"abc123","userIdHash":"user123abc"}"#
        XCTAssertEqual(
            LoginWindowController.userIdHash(fromCustomerInfoCookieValue: raw), "user123abc")

        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(
            LoginWindowController.userIdHash(fromCustomerInfoCookieValue: encoded), "user123abc")

        XCTAssertNil(LoginWindowController.userIdHash(fromCustomerInfoCookieValue: "not json"))
        XCTAssertNil(LoginWindowController.userIdHash(fromCustomerInfoCookieValue: #"{"userIdHash":""}"#))
    }
}
