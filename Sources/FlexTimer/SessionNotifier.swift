import Foundation
import UserNotifications

/// Posts one macOS notification when the Flex session expires (true→false
/// transition of `hasSession`), re-arming after a successful sign-in.
/// The poster is injected so the transition logic is testable; the real
/// poster comes from `live(onNotificationClick:)` and is only safe inside
/// a real .app bundle (attach in AppState.start(), like HookRunner).
final class SessionNotifier {
    private let post: () -> Void
    private var lastKnown: Bool?

    init(post: @escaping () -> Void) {
        self.post = post
    }

    func sessionBecame(_ hasSession: Bool) {
        defer { lastKnown = hasSession }
        guard let previous = lastKnown else { return }  // baseline: never notify
        if previous && !hasSession { post() }
    }

    /// Real UNUserNotificationCenter wiring. UNUserNotificationCenter.current()
    /// crashes outside a real .app bundle (swift test / swift run), hence the guard.
    @MainActor
    static func live(onNotificationClick: @escaping () -> Void) -> SessionNotifier {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return SessionNotifier(post: {})
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        NotificationClickDelegate.shared.onClick = onNotificationClick
        center.delegate = NotificationClickDelegate.shared
        return SessionNotifier(post: {
            let content = UNMutableNotificationContent()
            content.title = "칼퇴타이머"
            content.body = "Flex session expired — sign in again to keep tracking."
            center.add(UNNotificationRequest(identifier: "session-expired",
                                             content: content, trigger: nil))
        })
    }
}

/// Retained delegate for notification clicks (UNUserNotificationCenter holds
/// its delegate weakly).
final class NotificationClickDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationClickDelegate()
    var onClick: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        onClick?()
        completionHandler()
    }
}
