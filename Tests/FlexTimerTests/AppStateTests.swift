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
        XCTAssertEqual(state.labelText, "2:34")

        // Past leave time 17:59 (08:59 + 8h target + 1h break) → today's OT accrues
        // live: 19:00 − 17:59 = +1:01. Monday's +2h01 is no longer in the menu bar.
        // No `OT ` prefix: `labelText` is the Mac vocabulary's text, and the glyph
        // carries the phase. The prefix stays on the wire in `menuBarText` for the
        // Linux tray.
        state.recompute(now: d(2026, 7, 7, 19, 0))
        XCTAssertEqual(state.labelText, "+1:01")
    }

    func testNoRecordTodayShowsPlaceholder() {
        let state = AppState()
        state.hasSession = true
        state.week = []
        state.recompute(now: d(2026, 7, 7, 8, 0))
        XCTAssertEqual(state.labelText, "--:--")
    }

    /// Signed out is glyph-only: `labelText` is empty and the `zzz` glyph says it.
    /// `menuBarText`'s em dash lives on for the daemon, which has no glyph.
    func testNoSessionShowsNoText() {
        let state = AppState()
        state.hasSession = false
        state.recompute(now: d(2026, 7, 7, 8, 0))
        XCTAssertEqual(state.labelText, "")
    }

    func testManualStartDrivesCountdownAndWeeklySum() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        state.week = []
        let now = d(2026, 7, 9, 15, 25)
        SettingsStore.setManualStart(d(2026, 7, 9, 8, 59), on: now)
        state.recompute(now: now)
        XCTAssertEqual(state.labelText, "2:34")
    }

    func testExpiredSessionShowsNoTextDespiteStaleWeekData() {
        let state = AppState()
        state.hasSession = false
        state.week = [WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)]
        state.recompute(now: d(2026, 7, 9, 15, 0))
        XCTAssertEqual(state.labelText, "")
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
        XCTAssertEqual(state.labelText, "--:--")
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
        XCTAssertEqual(state.labelText, "1:20")

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
        state.timeOff = [Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0)): 4.0 * 3600]

        state.recompute(now: d(2026, 1, 2, 12, 35))
        XCTAssertEqual(state.labelText, "0:20")

        // Past 12:55 → overtime phase; today's OT = 13:00 − 12:55 = +0:05, measured
        // against the time-off-reduced 4h target.
        state.recompute(now: d(2026, 1, 2, 13, 0))
        XCTAssertEqual(state.labelText, "+0:05")
    }

    /// The picker only persists because `AppState` writes through on set — nothing
    /// else carries the choice to UserDefaults, so a lost `didSet` would silently
    /// reset the label geometry on every relaunch.
    func testLabelGeometryPickerWritesThroughToSettings() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        XCTAssertEqual(state.labelGeometry, .ring)

        state.labelGeometry = .track
        XCTAssertEqual(SettingsStore.labelGeometry, .track)

        state.labelGeometry = .ring
        XCTAssertEqual(SettingsStore.labelGeometry, .ring)
    }

    /// The cap→critical path through `recompute`. `computeDisplay` now takes the
    /// weekly total as a parameter, so the KaltoeCore tests can no longer catch a
    /// caller that computes it wrongly — this is the only test that does.
    ///
    /// Two parts, because `hasReachedWeeklyCap` is a one-sided `>=` threshold and
    /// each way of getting the total wrong moves it in a *fixed* direction:
    ///   0 ≤ (timeOff dropped) ≤ correct ≤ (state.week substituted)
    /// Passing `0` and dropping `timeOff:` under-count, so part 1 sits exactly on
    /// the cap and asserts `.critical`. Substituting `state.week` for
    /// `weekIncludingManual(now:)` over-counts, which can never pull an at-cap
    /// fixture back below the cap, so part 2 sits below it — with a stale
    /// previous-week record present — and asserts `.normal`.
    ///
    /// Formulas: target = 8h − familyDay(2h, last Friday only) − timeOff;
    /// break = 1h when target > 4h; net = clockOut − clockIn − break;
    /// daily OT = net − target; weekly = Σ max(0, daily OT); cap = 12h.
    /// 2026-07-27 is a Monday and 07-31 is the last Friday of July, so nothing
    /// below is a family day.
    func testWeeklyCapDrivesCriticalUrgencyThroughRecompute() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true

        // Part 1 — exactly on the cap, and only once time off is counted.
        // Mon–Wed 07-27..29, 08:00–20:00: 12h − 1h break = 11h net, target 8h → +3h
        //   each, 9h for the three.
        // Thu 07-30, 08:00–18:00 with 2h time off: target 8h − 2h = 6h, still > 4h so
        //   the 1h break applies; 10h − 1h = 9h net → 9h − 6h = +3h.
        // Correct total 9h + 3h = 12h == the 12h cap → .critical.
        // Drop `timeOff:` and Thursday's target is 8h → 9h − 8h = +1h, total 10h
        //   < 12h; the day is settled, so urgency falls to .normal.
        state.week = (27...29).map {
            WorkRecord(clockIn: d(2026, 7, $0, 8, 0), clockOut: d(2026, 7, $0, 20, 0), flexWorkedNet: nil)
        } + [WorkRecord(clockIn: d(2026, 7, 30, 8, 0), clockOut: d(2026, 7, 30, 18, 0), flexWorkedNet: nil)]
        state.timeOff = [Calendar.current.startOfDay(for: d(2026, 7, 30, 0, 0)): 2.0 * 3600]
        state.recompute(now: d(2026, 7, 30, 20, 30))
        XCTAssertEqual(state.menuDisplay.urgency, .critical)

        // Part 2 — below the cap, with a previous-week record still sitting in
        // `state.week`. No time off here.
        // Mon–Wed 07-27..29 as above = 9h; Thu 07-30, 08:00–17:00 is 9h − 1h = 8h net
        //   == the 8h target → +0h. Correct total 9h < 12h, day settled → .normal.
        // Monday 07-20 08:00–20:00 is another +3h but belongs to the *previous* week,
        //   so `weekIncludingManual(now:)` filters it out (clockIn < weekStart 07-27).
        //   A naive `state.week` counts it: 9h + 3h = 12h == the cap → .critical.
        state.timeOff = [:]
        state.week = [WorkRecord(clockIn: d(2026, 7, 20, 8, 0), clockOut: d(2026, 7, 20, 20, 0),
                                 flexWorkedNet: nil)]
            + (27...29).map {
                WorkRecord(clockIn: d(2026, 7, $0, 8, 0), clockOut: d(2026, 7, $0, 20, 0), flexWorkedNet: nil)
            }
            + [WorkRecord(clockIn: d(2026, 7, 30, 8, 0), clockOut: d(2026, 7, 30, 17, 0), flexWorkedNet: nil)]
        state.recompute(now: d(2026, 7, 30, 20, 30))
        XCTAssertEqual(state.menuDisplay.urgency, .normal)
    }

    func testUnlockResyncStopsOnceARecordArrives() {
        XCTAssertFalse(AppState.shouldRetryUnlockResync(attempt: 0, maxAttempts: 3,
                                                        hasSession: true, hasTodayRecord: true))
    }

    /// Retrying a dead session just hammers it — the sign-in notification is
    /// the recovery path, not another fetch.
    func testUnlockResyncStopsImmediatelyWhenSignedOut() {
        XCTAssertFalse(AppState.shouldRetryUnlockResync(attempt: 0, maxAttempts: 3,
                                                        hasSession: false, hasTodayRecord: false))
    }

    func testUnlockResyncStopsAtTheCeiling() {
        XCTAssertFalse(AppState.shouldRetryUnlockResync(attempt: 2, maxAttempts: 3,
                                                        hasSession: true, hasTodayRecord: false))
    }

    func testUnlockResyncContinuesWhileWaitingForARecord() {
        XCTAssertTrue(AppState.shouldRetryUnlockResync(attempt: 0, maxAttempts: 3,
                                                       hasSession: true, hasTodayRecord: false))
        XCTAssertTrue(AppState.shouldRetryUnlockResync(attempt: 1, maxAttempts: 3,
                                                       hasSession: true, hasTodayRecord: false))
    }
}

/// A separate class purely so it can carry `setUp`/`tearDown` without imposing them
/// on `AppStateTests`, whose sixteen methods isolate `SettingsStore.defaults`
/// per-method (or not at all). Retrofitting those is a logged follow-up, not this
/// change's business, and a class-level `setUp` here would retrofit all of them at
/// once.
@MainActor
final class AppStateWeekSummaryTests: XCTestCase {
    /// `weekSummary` reads `SettingsStore.rules` and, through `weekIncludingManual`,
    /// `SettingsStore.manualStart` — both of which the README tells users to set with
    /// `defaults write`. Without a throwaway suite this test would read the
    /// developer's own `dailyWorkHours`/`familyDayEarlyLeaveHours` and fail on their
    /// machine while passing on a clean one.
    ///
    /// Fixed, deliberately not `"flextimer-tests-\(UUID())"` as the neighbouring
    /// methods are: `removePersistentDomain` empties a suite but never unlinks its
    /// file, so a per-run UUID leaks one more .plist into ~/Library/Preferences every
    /// run — measured, and the reason 2000-odd `flextimer-tests-*.plist` have piled up
    /// there. One stable name keeps that at no more than one file forever; measured, it
    /// is currently none at all, because this test writes no keys and an unwritten
    /// suite's file is never created.
    private let suite = "flextimer-appstate-weeksummary-tests"

    /// Cleared on the way in as well as out, which is what makes a shared name safe:
    /// a run killed mid-test leaves its keys on disk for the next one to read.
    override func setUp() {
        SettingsStore.defaults = UserDefaults(suiteName: suite)!
        SettingsStore.defaults.removePersistentDomain(forName: suite)
    }

    /// `.standard` back as a neutral hand-back, matching `WeekSummaryTests`:
    /// `SettingsStore.defaults` is process-global across the whole bundle and class
    /// ordering is undefined, so leaving this suite installed would silently change
    /// what unrelated tests read. Returning the global as it was found is the choice
    /// that leaves no trace.
    override func tearDown() {
        SettingsStore.defaults.removePersistentDomain(forName: suite)
        SettingsStore.defaults = .standard
    }

    /// Pins the summary `recompute` publishes: five weekday rows in order, plus the
    /// week's overtime, Friday's worked figure and today's target note for this
    /// fixture.
    ///
    /// It asserts nothing about agreement with the menu bar pill, and could not:
    /// weekly overtime reaches the pill only through `hasReachedWeeklyCap`, and 35
    /// minutes is nowhere near the 12h cap, so at 14:41 the pill is in its countdown
    /// phase and this fixture exposes no pill-side figure to compare against.
    /// Divergence between the two is now prevented *structurally* instead — there is
    /// exactly one weekly-overtime derivation in `recompute`, and one local feeds the
    /// display, the notifier and this property, so there is no second pass left to
    /// disagree. `testWeeklyCapDrivesCriticalUrgencyThroughRecompute` above is the
    /// test that exercises that shared value at the one point it becomes observable.
    func testRecomputePublishesTheWeekSummary() {
        let state = AppState()
        state.hasSession = true
        state.week = [
            WorkRecord(clockIn: d(2026, 7, 27, 9, 0), clockOut: d(2026, 7, 27, 18, 35),
                       flexWorkedNet: nil),
            WorkRecord(clockIn: d(2026, 7, 31, 9, 12), clockOut: nil, flexWorkedNet: nil),
        ]
        state.recompute(now: d(2026, 7, 31, 14, 41))

        // Aborting, unlike XCTAssertEqual: that reports and carries on, so a regression
        // that emptied `days` would trap on the `days[4]` subscript below and take the
        // whole test process down. A crash reports far worse than a failure does.
        guard state.weekSummary.days.count == 5 else {
            return XCTFail("expected 5 weekday rows, got \(state.weekSummary.days.count)")
        }
        XCTAssertEqual(state.weekSummary.days.map(\.label), ["월", "화", "수", "목", "금"])
        XCTAssertEqual(state.weekSummary.overtime, 35 * 60)  // Monday's +0:35 only
        XCTAssertEqual(state.weekSummary.days[4].worked, 4 * 3600 + 29 * 60)
        // 2026-07-31 is the last Friday of July.
        XCTAssertEqual(state.weekSummary.targetNote, "Target 6:00 · family day")
    }
}
