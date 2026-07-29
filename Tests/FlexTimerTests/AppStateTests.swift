import XCTest
@testable import FlexTimer
import KaltoeCore

/// Date in Asia/Seoul, gregorian.
/// Duplicated from KaltoeCoreTests/WorkCalculatorTests.swift: separate test
/// targets don't share top-level helpers across the split.
private func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
}

@MainActor
final class AppStateTests: XCTestCase {
    func testRecomputePicksTodayAndSetsMenuText() {
        let state = AppState()
        state.hasSession = true
        state.week = [
            WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil),
            WorkRecord(clockIn: d(2026, 7, 7, 8, 59), clockOut: nil, flexWorkedNet: nil),
        ]
        state.recompute(now: d(2026, 7, 7, 15, 25)) // Tuesday 15:25, clocked in 08:59
        XCTAssertEqual(state.menuText, "2:34")

        // Past leave time 17:59 (08:59 + 8h target + 1h break) → today's OT accrues
        // live: 19:00 − 17:59 = +1:01. Monday's +2h01 is no longer in the menu bar.
        state.recompute(now: d(2026, 7, 7, 19, 0))
        XCTAssertEqual(state.menuText, "OT +1:01")
    }

    func testNoRecordTodayShowsPlaceholder() {
        let state = AppState()
        state.hasSession = true
        state.week = []
        state.recompute(now: d(2026, 7, 7, 8, 0))
        XCTAssertEqual(state.menuText, "--:--")
    }

    func testNoSessionShowsDash() {
        let state = AppState()
        state.hasSession = false
        state.recompute(now: d(2026, 7, 7, 8, 0))
        XCTAssertEqual(state.menuText, "—")
    }

    func testManualStartDrivesCountdownAndWeeklySum() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        state.week = []
        let now = d(2026, 7, 9, 15, 25)
        SettingsStore.setManualStart(d(2026, 7, 9, 8, 59), on: now)
        state.recompute(now: now)
        XCTAssertEqual(state.menuText, "2:34")
    }

    func testExpiredSessionShowsDashDespiteStaleWeekData() {
        let state = AppState()
        state.hasSession = false
        state.week = [WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)]
        state.recompute(now: d(2026, 7, 9, 15, 0))
        XCTAssertEqual(state.menuText, "—")
    }

    func testWeekRolloverDropsLastWeeksRecordsFromSum() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        // Record from Friday 2026-07-10; now is Monday 2026-07-13 00:05 (new week)
        state.week = [WorkRecord(clockIn: d(2026, 7, 10, 9, 0), clockOut: d(2026, 7, 10, 20, 1), flexWorkedNet: nil)]
        state.recompute(now: d(2026, 7, 13, 0, 5))
        // New week, no record today → not clocked in; the gross weekly sum must NOT
        // include Friday, whose own overtime was 11h01 elapsed − 1h break − 8h = +2h01.
        XCTAssertEqual(state.menuText, "--:--")
        XCTAssertEqual(WorkCalculator.weeklyOvertime(
            records: state.weekIncludingManual(now: d(2026, 7, 13, 0, 5)),
            now: d(2026, 7, 13, 0, 5), rules: state.rules), 0)
    }

    func testRecomputePublishesMenuDisplayPhases() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        state.week = [WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)]

        state.recompute(now: d(2026, 7, 9, 10, 0))
        XCTAssertEqual(state.menuDisplay.state, .toLunch(timeLeft: 80 * 60)) // 10:00 → 11:20
        XCTAssertEqual(state.menuText, "1:20")

        state.recompute(now: d(2026, 7, 9, 17, 55))
        XCTAssertEqual(state.menuDisplay.urgency, .critical) // 5 min to 18:00
    }

    func testRecomputeFiresHooksWhenRunnerAttached() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        state.week = [WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)]
        var fired: [String] = []
        state.hookRunner = HookRunner(defaults: SettingsStore.defaults) { url, _ in
            fired.append(url.lastPathComponent)
        }
        state.recompute(now: d(2026, 7, 9, 10, 0))
        XCTAssertEqual(fired, ["on-clock-in"])
    }

    func testSessionExpiryNotifiesViaAttachedNotifier() {
        let state = AppState()
        var posted = 0
        state.sessionNotifier = SessionNotifier { posted += 1 }
        state.sessionNotifier?.sessionBecame(state.hasSession)  // baseline, as start() does
        let wasSignedIn = state.hasSession
        state.hasSession = true      // ensure a true baseline regardless of Keychain state
        state.hasSession = false     // expiry
        XCTAssertEqual(posted, 1)
        state.hasSession = wasSignedIn  // restore for other tests' AppState instances
    }

    func testHalfDayDrivesReducedCountdownAndWeeklySum() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        // Half-day Friday 2026-01-02, clocked in 08:55, 4h off → leave 12:55 (no lunch
        // in the leave-time math; 12:35 is past the lunch-phase window, so the menu
        // shows the plain countdown).
        state.week = [WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: nil, flexWorkedNet: nil)]
        state.timeOff = [Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0)): 4 * 3600]

        state.recompute(now: d(2026, 1, 2, 12, 35))
        XCTAssertEqual(state.menuText, "0:20")

        // Past 12:55 → overtime phase; today's OT = 13:00 − 12:55 = +0:05, measured
        // against the time-off-reduced 4h target.
        state.recompute(now: d(2026, 1, 2, 13, 0))
        XCTAssertEqual(state.menuText, "OT +0:05")
    }

    func testHighContrastToggleWritesThroughToSettings() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        XCTAssertFalse(state.highContrastOnInactiveDisplays)

        state.highContrastOnInactiveDisplays = true
        XCTAssertTrue(SettingsStore.highContrastOnInactiveDisplays)

        state.highContrastOnInactiveDisplays = false
        XCTAssertFalse(SettingsStore.highContrastOnInactiveDisplays)
    }
}
