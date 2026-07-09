import XCTest
@testable import FlexTimer

final class LoginWindowTests: XCTestCase {
    func testUserIdHashDecoding() {
        let raw = #"{"customerIdHash":"abc123","userIdHash":"SCRUBBEDHASH"}"#
        XCTAssertEqual(
            LoginWindowController.userIdHash(fromCustomerInfoCookieValue: raw), "SCRUBBEDHASH")

        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(
            LoginWindowController.userIdHash(fromCustomerInfoCookieValue: encoded), "SCRUBBEDHASH")

        XCTAssertNil(LoginWindowController.userIdHash(fromCustomerInfoCookieValue: "not json"))
        XCTAssertNil(LoginWindowController.userIdHash(fromCustomerInfoCookieValue: #"{"userIdHash":""}"#))
    }
}
