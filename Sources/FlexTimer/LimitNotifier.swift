import Foundation
import UserNotifications
import KaltoeCore

/// Posts at most one macOS notification per period when a company overtime
/// limit is crossed: the weekly cap once per week, the nightly cutoff once per
/// day.
///
/// Dedupe is the substance of this type, not a detail. `AppState.recompute`
/// runs every second, so an undeduped notifier would fire thousands of times an
/// hour. Each limit stores the stamp of the period it last notified for under a
/// fixed key — so it re-arms when the period changes, never accumulates keys,
/// and survives relaunch (reopening the app at 22:30 must not re-notify).
///
/// The poster is injected so the logic is testable; the real poster comes from
/// `live()` and is only safe inside a real .app bundle (attach in
/// AppState.start(), like HookRunner and SessionNotifier).
final class LimitNotifier {
    private static let capKey = "limitNotifiedCapWeek"
    private static let cutoffKey = "limitNotifiedCutoffDay"

    private let post: (String) -> Void
    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults, calendar: Calendar = .current,
         post: @escaping (String) -> Void) {
        self.defaults = defaults
        self.calendar = calendar
        self.post = post
    }

    func evaluate(weeklyOvertime: TimeInterval, clockedIn: Bool, now: Date, rules: WorkRules) {
        if WorkCalculator.hasReachedWeeklyCap(weeklyOvertime: weeklyOvertime, rules: rules) {
            let week = WorkCalculator.weekStart(of: now, calendar: calendar)
            fireOnce(key: Self.capKey, stamp: stamp(week),
                     body: "Weekly overtime cap reached — stop for this week.")
        }
        if clockedIn, WorkCalculator.isPastOvertimeCutoff(now: now, rules: rules,
                                                          calendar: calendar) {
            fireOnce(key: Self.cutoffKey, stamp: stamp(now),
                     body: "Past the overtime cutoff — clock out and go home.")
        }
    }

    private func fireOnce(key: String, stamp: String, body: String) {
        guard defaults.string(forKey: key) != stamp else { return }
        defaults.set(stamp, forKey: key)
        post(body)
    }

    private func stamp(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Real UNUserNotificationCenter wiring. UNUserNotificationCenter.current()
    /// crashes outside a real .app bundle (swift test / swift run), hence the guard.
    @MainActor
    static func live() -> LimitNotifier {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return LimitNotifier(defaults: .standard, post: { _ in })
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        return LimitNotifier(defaults: .standard) { body in
            let content = UNMutableNotificationContent()
            content.title = "칼퇴타이머"
            content.body = body
            center.add(UNNotificationRequest(identifier: "overtime-limit-\(UUID().uuidString)",
                                             content: content, trigger: nil))
        }
    }
}
