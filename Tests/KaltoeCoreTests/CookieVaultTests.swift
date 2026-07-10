import XCTest
@testable import KaltoeCore

final class CookieVaultTests: XCTestCase {
    override func setUp() {
        useScratchVault()
    }
    override func tearDown() { CookieVault.clear() }

    #if os(macOS)
    func testDefaultServiceIsSacrificialUnderXCTest() {
        // Guards the securityd-prompt fix: when XCTest is loaded, the default
        // service must NOT be the real session item, so AppState() in tests
        // never triggers a keychain consent prompt for the user's Flex session.
        XCTAssertEqual(CookieVault.defaultService, "com.perso.flextimer.session.test")
    }
    #endif

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

#if !os(macOS)
extension CookieVaultTests {
    func testTrayWrittenSessionFileRoundTrips() throws {
        let url = CookieVault.sessionFileOverride!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Exactly what kaltoe-tray.py writes: epoch-seconds expires, null allowed.
        let tray = #"{"userIdHash":"u123","cookies":[{"name":"AID","value":"a","domain":".flex.team","path":"/","expires":2000000000},{"name":"V2_WS_AID","value":"w","domain":".flex.team","path":"/","expires":null}]}"#
        try tray.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(CookieVault.loadUserIdHash(), "u123")
        let cookies = CookieVault.load()
        XCTAssertEqual(cookies?.map(\.name), ["AID", "V2_WS_AID"])
        XCTAssertEqual(cookies?[0].expires, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(cookies?[1].expires)
    }

    func testSaveStoredPreservesUserIdHash() throws {
        let url = CookieVault.sessionFileOverride!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"userIdHash":"u123","cookies":[]}"#.data(using: .utf8)!.write(to: url)
        CookieVault.saveStored([StoredCookie(name: "AID", value: "x", domain: ".flex.team",
                                             path: "/", expires: nil)])
        XCTAssertEqual(CookieVault.loadUserIdHash(), "u123",
                       "cookie refresh must not drop the tray-written hash")
    }

    func testSessionFileWrittenOwnerOnly() throws {
        CookieVault.saveStored([StoredCookie(name: "AID", value: "x", domain: ".flex.team",
                                             path: "/", expires: nil)])
        let attrs = try FileManager.default.attributesOfItem(
            atPath: CookieVault.sessionFileOverride!.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSessionFileStaysOwnerOnlyAfterOverwrite() throws {
        // saveStored called twice on the same path (a cookie refresh) must not
        // relax permissions on the second, overwriting write.
        CookieVault.saveStored([StoredCookie(name: "AID", value: "x", domain: ".flex.team",
                                             path: "/", expires: nil)])
        CookieVault.saveStored([StoredCookie(name: "AID", value: "y", domain: ".flex.team",
                                             path: "/", expires: nil)])
        let attrs = try FileManager.default.attributesOfItem(
            atPath: CookieVault.sessionFileOverride!.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(CookieVault.load()?.map(\.value), ["y"])
    }

    func testWellFormedEmptyCookiesArrayLoadsAsNil() throws {
        let url = CookieVault.sessionFileOverride!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"userIdHash":"u123","cookies":[]}"#.data(using: .utf8)!.write(to: url)
        XCTAssertNil(CookieVault.load())
    }
}
#endif
