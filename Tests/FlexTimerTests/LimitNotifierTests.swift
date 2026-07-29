import XCTest
@testable import FlexTimer
import KaltoeCore

/// Date in Asia/Seoul, gregorian. Duplicated per this repo's convention:
/// separate test targets don't share top-level helpers.
private func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
}

private let seoul: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return c
}()

final class LimitNotifierTests: XCTestCase {
    private var posted: [String] = []
    private var defaults: UserDefaults!
    private var notifier: LimitNotifier!
    private let rules = WorkRules()   // 12h cap, 22:00 cutoff

    override func setUp() {
        posted = []
        defaults = UserDefaults(suiteName: "limit-tests-\(UUID().uuidString)")!
        notifier = LimitNotifier(defaults: defaults, calendar: seoul) { [self] in posted.append($0) }
    }

    func testCapFiresOnceThenStaysSilent() {
        let now = d(2026, 7, 29, 18, 0)
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true, now: now, rules: rules)
        XCTAssertEqual(posted.count, 1)
        // recompute runs every second — the next ticks must be silent
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 18, 1), rules: rules)
        notifier.evaluate(weeklyOvertime: 13 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 19, 0), rules: rules)
        XCTAssertEqual(posted.count, 1)
    }

    func testCapDoesNotFireBelowTheCeiling() {
        notifier.evaluate(weeklyOvertime: 11 * 3600 + 3599, clockedIn: true,
                          now: d(2026, 7, 29, 18, 0), rules: rules)
        XCTAssertEqual(posted, [])
    }

    func testCapReArmsInANewWeek() {
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 18, 0), rules: rules)   // Wed
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 8, 5, 18, 0), rules: rules)    // next Wed
        XCTAssertEqual(posted.count, 2)
    }

    func testCutoffFiresOnceThenStaysSilent() {
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 29, 22, 0), rules: rules)
        XCTAssertEqual(posted.count, 1)
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 29, 22, 30), rules: rules)
        XCTAssertEqual(posted.count, 1)
    }

    func testCutoffStaysSilentWhenClockedOut() {
        notifier.evaluate(weeklyOvertime: 0, clockedIn: false,
                          now: d(2026, 7, 29, 23, 0), rules: rules)
        XCTAssertEqual(posted, [])
    }

    func testCutoffReArmsTheNextDay() {
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 29, 22, 30), rules: rules)
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 30, 22, 30), rules: rules)
        XCTAssertEqual(posted.count, 2)
    }

    /// Relaunching the app after a crossing must not re-notify: a fresh
    /// notifier over the same defaults sees the stored stamp.
    func testDoesNotReFireAfterRelaunch() {
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 22, 30), rules: rules)
        XCTAssertEqual(posted.count, 2)   // cap + cutoff both crossed
        let relaunched = LimitNotifier(defaults: defaults, calendar: seoul) { [self] in posted.append($0) }
        relaunched.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                            now: d(2026, 7, 29, 22, 31), rules: rules)
        XCTAssertEqual(posted.count, 2)
    }

    @MainActor
    func testLiveFactoryIsInertOutsideAppBundle() {
        // Under swift test the main bundle is not a .app, so live() must return
        // a notifier whose poster never touches UNUserNotificationCenter.
        let live = LimitNotifier.live()
        live.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                      now: d(2026, 7, 29, 22, 30), rules: rules)
        // Reaching here without a bundleProxy crash is the assertion.
    }
}
