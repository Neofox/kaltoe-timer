import XCTest
@testable import FlexTimer

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

        state.recompute(now: d(2026, 7, 7, 19, 0)) // past 17:59 → weekly OT: −5h +2h01 +1h01 = −1:58
        XCTAssertEqual(state.menuText, "OT -1:58")
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
        // New week, no record today → not clocked in; weekly sum must NOT include Friday
        XCTAssertEqual(state.menuText, "--:--")
        XCTAssertEqual(WorkCalculator.weeklyOvertime(
            records: state.weekIncludingManual(now: d(2026, 7, 13, 0, 5)),
            now: d(2026, 7, 13, 0, 5), rules: state.rules), -5 * 3600)
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

    func testDayOffAdjustsWeeklyCounterInMenuText() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        // Mon 2026-07-06 worked 9h net (09:00–19:00 minus 1h break) → +1h;
        // Tue 2026-07-07 worked 8h net (09:00–18:00 minus 1h break) → 0h.
        // Thursday 2026-07-09 is a vacation day.
        state.week = [
            WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 19, 0), flexWorkedNet: nil),
            WorkRecord(clockIn: d(2026, 7, 7, 9, 0), clockOut: d(2026, 7, 7, 18, 0), flexWorkedNet: nil),
        ]
        state.dayOffDates = [Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))]
        // Tuesday 19:00: today's record is completed and past leave time → overtime phase.
        // Weekly counter: −(5−1)h + 1h + 0h = −3:00
        state.recompute(now: d(2026, 7, 7, 19, 0))
        XCTAssertEqual(state.menuText, "OT -3:00")
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
}
