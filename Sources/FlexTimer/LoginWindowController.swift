import AppKit
import WebKit

/// Shows the real flex.team login page in a webview; when the session cookies
/// appear, saves them to the CookieVault, closes, and fires onSuccess.
final class LoginWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var onSuccess: (() -> Void)?

    func show(onSuccess: @escaping () -> Void) {
        self.onSuccess = onSuccess
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.load(URLRequest(url: FlexAPIConfig.loginURL))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Sign in to Flex"
        win.contentView = web
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        webView = web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, self.onSuccess != nil else { return }
            let flexCookies = cookies.filter { $0.domain.contains("flex.team") }
            let names = Set(flexCookies.map(\.name))
            guard FlexAPIConfig.sessionCookieNames.isSubset(of: names) else { return }
            CookieVault.save(flexCookies)
            if let customerInfo = flexCookies.first(where: { $0.name == "V2_CUSTOMER_INFO" }),
               let hash = Self.userIdHash(fromCustomerInfoCookieValue: customerInfo.value) {
                UserDefaults.standard.set(hash, forKey: "flexUserIdHash")
            }
            let done = self.onSuccess
            self.onSuccess = nil
            self.close()
            done?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
    }

    private func close() {
        window?.close()
    }

    /// Extracts userIdHash from a V2_CUSTOMER_INFO cookie value (percent-encoded JSON).
    static func userIdHash(fromCustomerInfoCookieValue value: String) -> String? {
        guard let decoded = value.removingPercentEncoding,
              let data = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hash = json["userIdHash"] as? String, !hash.isEmpty else { return nil }
        return hash
    }
}
