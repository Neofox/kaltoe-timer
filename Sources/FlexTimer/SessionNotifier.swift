import Foundation
import UserNotifications

/// Posts one macOS notification when the Flex session expires (true→false
/// transition of `hasSession`), re-arming after a successful sign-in.
/// The poster is injected so the transition logic is testable; the real
/// poster comes from `live(onNotificationClick:)` and is only safe inside
/// a real .app bundle (attach in AppState.start(), like HookRunner).
final class SessionNotifier {
    /// Identifier of the session-expiry notification. Fixed (not a UUID) so the
    /// click delegate can tell it apart from the app's other notifications.
    static let identifier = "session-expired"

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
            center.add(UNNotificationRequest(identifier: SessionNotifier.identifier,
                                             content: content, trigger: nil))
        })
    }
}

/// Retained delegate for notification clicks (UNUserNotificationCenter holds
/// its delegate weakly).
@MainActor
final class NotificationClickDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationClickDelegate()
    var onClick: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // The app posts more than one kind of notification (session expiry plus
        // the overtime-limit ones), and only session expiry has a click action —
        // opening the Flex sign-in window. Without this filter, clicking "Past
        // the overtime cutoff" would pop up a login window. Keep the guard.
        guard response.notification.request.identifier == SessionNotifier.identifier else {
            completionHandler()
            return
        }
        onClick?()
        completionHandler()
    }
}
