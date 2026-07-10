import Foundation
import Security

struct StoredCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?

    init(name: String, value: String, domain: String, path: String, expires: Date?) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires
    }

    init(_ c: HTTPCookie) {
        self.init(name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expiresDate)
    }
}

/// Stores the Flex session cookies as one JSON blob in the login Keychain.
enum CookieVault {
    /// Under XCTest the default points at a sacrificial item, so tests that
    /// construct AppState (whose init reads the vault) never touch the user's
    /// real session item — reading a foreign-ACL item is what triggers the
    /// securityd consent prompt for xctest and hangs unattended test runs.
    static let defaultService = NSClassFromString("XCTestCase") == nil
        ? "com.perso.flextimer.session"
        : "com.perso.flextimer.session.test"
    static var service = defaultService
    private static let account = "flex"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ cookies: [HTTPCookie]) {
        saveStored(cookies.map(StoredCookie.init))
    }

    static func saveStored(_ cookies: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> [StoredCookie]? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let cookies = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return nil }
        return cookies
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
