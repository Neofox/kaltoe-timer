import Foundation

#if !os(macOS)
/// Single source of truth for the Linux config directory, shared by
/// CookieVault (session.json) and HookRunner (hooks/):
/// $KALTOE_CONFIG_DIR if set, else ~/.config/kaltoe-timer.
enum LinuxPaths {
    static var configDirectory: URL {
        ProcessInfo.processInfo.environment["KALTOE_CONFIG_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/kaltoe-timer", isDirectory: true)
    }
}
#endif
