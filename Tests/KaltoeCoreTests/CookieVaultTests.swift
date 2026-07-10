import XCTest
@testable import KaltoeCore

final class CookieVaultTests: XCTestCase {
    override func setUp() {
        CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
    }
    override func tearDown() { CookieVault.clear() }

    func testDefaultServiceIsSacrificialUnderXCTest() {
        // Guards the securityd-prompt fix: when XCTest is loaded, the default
        // service must NOT be the real session item, so AppState() in tests
        // never triggers a keychain consent prompt for the user's Flex session.
        XCTAssertEqual(CookieVault.defaultService, "com.perso.flextimer.session.test")
    }

    func testRoundTripAndClear() {
        let cookies = [
            StoredCookie(name: "SID", value: "abc123", domain: ".flex.team", path: "/", expires: nil),
            StoredCookie(name: "RID", value: "xyz", domain: "flex.team", path: "/", expires: Date(timeIntervalSince1970: 2_000_000_000)),
        ]
        CookieVault.saveStored(cookies)
        XCTAssertEqual(CookieVault.load(), cookies)

        CookieVault.clear()
        XCTAssertNil(CookieVault.load())
    }

    func testSaveOverwrites() {
        CookieVault.saveStored([StoredCookie(name: "A", value: "1", domain: "flex.team", path: "/", expires: nil)])
        CookieVault.saveStored([StoredCookie(name: "B", value: "2", domain: "flex.team", path: "/", expires: nil)])
        XCTAssertEqual(CookieVault.load()?.map(\.name), ["B"])
    }
}
