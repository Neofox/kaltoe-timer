import Foundation
@testable import KaltoeCore

/// Points CookieVault at a scratch store so tests never touch the real session.
func useScratchVault() {
    #if os(macOS)
    CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
    #else
    CookieVault.sessionFileOverride = FileManager.default.temporaryDirectory
        .appendingPathComponent("kaltoe-vault-test-\(UUID().uuidString)/session.json")
    #endif
}
