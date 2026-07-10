import Foundation
import Security

public struct StoredCookie: Codable, Equatable {
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

/// Stores the Flex session cookies as one JSON blob in the login Keychain.
public enum CookieVault {
    /// Under XCTest the default points at a sacrificial item, so tests that
    /// construct AppState (whose init reads the vault) never touch the user's
    /// real session item — reading a foreign-ACL item is what triggers the
    /// securityd consent prompt for xctest and hangs unattended test runs.
    public static let defaultService = NSClassFromString("XCTestCase") == nil
        ? "com.perso.flextimer.session"
        : "com.perso.flextimer.session.test"
    public static var service = defaultService
    private static let account = "flex"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func save(_ cookies: [HTTPCookie]) {
        saveStored(cookies.map(StoredCookie.init))
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
