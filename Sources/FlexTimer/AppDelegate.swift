import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        registerAsLoginItem()
    }

    /// Adds the app to Login Items on launch so it starts automatically.
    /// Only from a real .app bundle — `swift run`/tests must not register a
    /// debug binary. Errors are deliberately swallowed: once a user disables
    /// the item in System Settings, macOS rejects register() and their
    /// choice must stand.
    private func registerAsLoginItem() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }
}
