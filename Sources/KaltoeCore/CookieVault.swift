import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Security
#endif

public struct StoredCookie: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?

    public init(name: String, value: String, domain: String, path: String, expires: Date?) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires
    }

    public init(_ c: HTTPCookie) {
        self.init(name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expiresDate)
    }
}

#if os(macOS)
/// Stores the Flex session cookies as one JSON blob in the login Keychain.
public enum CookieVault {
    /// Under XCTest the default points at a sacrificial item, so tests that
    /// construct AppState (whose init reads the vault) never touch the user's
    /// real session item — reading a foreign-ACL item is what triggers the
    /// securityd consent prompt for xctest and hangs unattended test runs.
    public static let defaultService = NSClassFromString("XCTestCase") == nil
        ? "com.perso.flextimer.session"
        : "com.perso.flextimer.session.test"
    nonisolated(unsafe) public static var service = defaultService
    private static let account = "flex"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func saveStored(_ cookies: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func load() -> [StoredCookie]? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let cookies = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return nil }
        return cookies
    }

    public static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
#else
/// Linux: the session lives as JSON at ~/.config/kaltoe-timer/session.json
/// (0600), written by the tray frontend at login and read/updated here.
/// `expires` dates are Unix epoch seconds (the tray writes GLib to_unix()).
public enum CookieVault {
    struct SessionFile: Codable {
        var userIdHash: String
        var cookies: [StoredCookie]
    }

    /// Test seam — points reads/writes at a scratch file.
    public static var sessionFileOverride: URL?

    static var sessionFileURL: URL {
        if let sessionFileOverride { return sessionFileOverride }
        return LinuxPaths.configDirectory.appendingPathComponent("session.json")
    }

    private static func readFile() -> SessionFile? {
        guard let data = try? Data(contentsOf: sessionFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SessionFile.self, from: data)
    }

    public static func load() -> [StoredCookie]? {
        guard let file = readFile(), !file.cookies.isEmpty else { return nil }
        return file.cookies
    }

    /// The per-user Flex id captured at login; empty before first sign-in.
    public static func loadUserIdHash() -> String {
        readFile()?.userIdHash ?? ""
    }

    public static func saveStored(_ cookies: [StoredCookie]) {
        // Preserve the hash the tray wrote — cookie refreshes must not drop it.
        let file = SessionFile(userIdHash: readFile()?.userIdHash ?? "", cookies: cookies)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: sessionFileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sessionFileURL.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: sessionFileURL)
    }
}
#endif

extension CookieVault {
    public static func save(_ cookies: [HTTPCookie]) {
        saveStored(cookies.map(StoredCookie.init))
    }
}
