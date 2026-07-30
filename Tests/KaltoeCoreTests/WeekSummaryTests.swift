import XCTest
@testable import KaltoeCore

final class TargetNoteTests: XCTestCase {
    /// An ordinary Wednesday: nothing shortened the day, so there is nothing to say.
    func testOrdinaryDayHasNoNote() {
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 29, 9, 0), rules: rules, timeOff: [:]))
    }

    /// 2026-07-31 is the last Friday of July, so the family-day reduction applies.
    func testFamilyDayAlone() {
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: rules, timeOff: [:]),
                       "Target 6:00 · family day")
    }

    func testTimeOffAlone() {
        let key = Calendar.current.startOfDay(for: d(2026, 7, 29, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 29, 9, 0), rules: rules,
                                          timeOff: [key: 2.0 * 3600]),
                       "Target 6:00 · time off")
    }

    /// The compounding case, and the reason this feature exists: both reductions
    /// land on one day, and because a 4h target is at or below half a day the break
    /// vanishes with them, so Leave at moves five hours, not four — 18:12 to 13:12
    /// (clock-in + 8h + 1h break, versus clock-in + 4h + no break).
    func testFamilyDayAndTimeOffStack() {
        let key = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: rules,
                                          timeOff: [key: 2.0 * 3600]),
                       "Target 4:00 · family day, time off")
    }

    /// A Friday that is not the last one in its month is an ordinary day.
    func testNonFinalFridayIsNotAFamilyDay() {
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 24, 9, 0), rules: rules, timeOff: [:]))
    }

    /// familyDayEarlyLeave == 0 disables the whole policy (WorkRules' documented
    /// convention), so the note must disappear with it.
    func testFamilyDayDisabledByRules() {
        var off = WorkRules()
        off.familyDayEarlyLeave = 0
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: off, timeOff: [:]))
    }

    /// The only test that exercises the **rejection** side of compose's
    /// `rules.familyDayEarlyLeave > 0` clause. testFamilyDayAlone reaches the same
    /// clause but takes its true branch, and testFamilyDayDisabledByRules never
    /// reaches it at all — it exits at the earlier `target < rules.dailyWork` guard.
    /// Only here is the clause met on a real family day with familyDayEarlyLeave == 0,
    /// so without this, deleting it leaves the whole suite green while a disabled
    /// policy gets named in the caption.
    func testFamilyDayDisabledStillNamesTimeOffAlone() {
        var off = WorkRules()
        off.familyDayEarlyLeave = 0
        let key = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: off,
                                          timeOff: [key: 2.0 * 3600]),
                       "Target 6:00 · time off")
    }
}

final class WeekSummaryTests: XCTestCase {
    /// `compute` reaches SettingsStore.manualStart through `weekIncludingManual`,
    /// so without this a stray manual start in the developer's own domain would
    /// materialise a row. Torn down rather than merely abandoned: leaked suites
    /// accumulate as .plist files in ~/Library/Preferences.
    /// Fixed, deliberately not `"weeksummary-tests-\(UUID())"` as the other suites
    /// in this repo are. `removePersistentDomain` empties a suite's contents but
    /// does not unlink its file, so a per-run UUID leaves one more empty .plist in
    /// ~/Library/Preferences every single run — measured, and the reason 2000-odd
    /// `flextimer-tests-*.plist` have piled up there. One stable name keeps that at
    /// exactly one file forever.
    private let suite = "weeksummary-tests"

    /// Cleared on the way in as well as out, which is what makes a shared name safe:
    /// a run killed mid-test leaves its manual start on disk, and this is what stops
    /// the next run from reading it.
    override func setUp() {
        SettingsStore.defaults = UserDefaults(suiteName: suite)!
        SettingsStore.defaults.removePersistentDomain(forName: suite)
    }

    /// Restores `.standard` purely as a neutral hand-back — the state this class was
    /// handed, returned as it was found — not because it protects anyone. It does not:
    /// `SettingsStore.defaults` is process-global across every target in this bundle,
    /// and `Tests/FlexTimerTests/AppStateTests.swift` has no `setUp` and assigns it in
    /// only about half its methods, so the rest simply inherit whatever ran last. For
    /// those, restoring `.standard` re-exposes them to the developer's real domain,
    /// where leaving the global on this emptied throwaway would have isolated them.
    /// Neither is a guarantee — cross-target class ordering is not defined — so this
    /// picks the choice that leaves no trace. Isolating `AppStateTests` is its own job.
    override func tearDown() {
        SettingsStore.defaults.removePersistentDomain(forName: suite)
        SettingsStore.defaults = .standard
    }

    /// The canonical week from the plan: Mon 8:35, Tue 9:10, Wed 7:40, Thu off,
    /// Fri open from 09:12 and a family day. Week OT = 1:45.
    private var week: WeekData {
        WeekData(
            records: [
                WorkRecord(clockIn: d(2026, 7, 27, 9, 0), clockOut: d(2026, 7, 27, 18, 35),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 28, 9, 0), clockOut: d(2026, 7, 28, 19, 10),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: d(2026, 7, 29, 17, 40),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 31, 9, 12), clockOut: nil, flexWorkedNet: nil),
            ],
            dayOffDates: [Calendar.current.startOfDay(for: d(2026, 7, 30, 0, 0))],
            timeOff: [:])
    }

    private let now = d(2026, 7, 31, 14, 41)

    private func summary(_ data: WeekData? = nil, now override: Date? = nil) -> WeekSummary {
        WeekSummary.compute(from: data ?? week, now: override ?? now, rules: rules)
    }

    func testAlwaysFiveWeekdayRowsInOrder() {
        XCTAssertEqual(summary().days.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri"])
        // The labels are a fixed array, so they alone prove nothing about which days
        // the rows stand for: a Sunday-first weekStart would still read Mon...Fri.
        // Monday of the canonical week is 2026-07-27.
        XCTAssertEqual(summary().days[0].date,
                       Calendar.current.startOfDay(for: d(2026, 7, 27, 0, 0)))
    }

    /// Five rows even with no records at all — the strip must not collapse.
    func testFiveRowsWithAnEmptyWeek() {
        let empty = summary(WeekData())
        XCTAssertEqual(empty.days.count, 5)
        XCTAssertTrue(empty.days.allSatisfy { $0.worked == nil })
        XCTAssertEqual(empty.overtime, 0)
    }

    func testCompletedDaysDeductTheBreak() {
        let days = summary().days
        XCTAssertEqual(days[0].worked, 8 * 3600 + 35 * 60)   // 09:00–18:35 − 1h
        XCTAssertEqual(days[1].worked, 9 * 3600 + 10 * 60)
        XCTAssertEqual(days[2].worked, 7 * 3600 + 40 * 60)
    }

    /// Flex's own net figure wins when supplied, matching dailyOvertime.
    func testFlexNetWorkedIsPreferredWhenPresent() {
        let data = WeekData(records: [
            WorkRecord(clockIn: d(2026, 7, 27, 9, 0), clockOut: d(2026, 7, 27, 18, 35),
                       flexWorkedNet: 7 * 3600)
        ])
        XCTAssertEqual(summary(data).days[0].worked, 7 * 3600)
        // Also the only case reaching dailyOvertime's flexWorkedNet branch: 7h against
        // an 8h target is -1h, floored to 0 rather than shown as a negative row.
        XCTAssertEqual(summary(data).days[0].overtime, 0)
    }

    /// 09:12 to 14:41 is 5:29 elapsed, and lunch is fully spent by then, so 4:29.
    func testOngoingDayDeductsOnlyTheBreakAlreadyTaken() {
        XCTAssertEqual(summary().days[4].worked, 4 * 3600 + 29 * 60)
        XCTAssertTrue(summary().days[4].isOngoing)
    }

    /// The case breakTaken exists for: at 10:00 nothing has been deducted, so the
    /// bar shows 48 minutes rather than sitting at zero.
    func testOngoingDayBeforeLunchDeductsNothing() {
        let early = summary(now: d(2026, 7, 31, 10, 0))
        XCTAssertEqual(early.days[4].worked, 48 * 60)
    }

    func testDayOffIsMarkedAndHasNoWork() {
        let thursday = summary().days[3]
        XCTAssertTrue(thursday.isDayOff)
        XCTAssertNil(thursday.worked)
        XCTAssertFalse(thursday.isOngoing)
    }

    /// Friday is the last Friday of July, so its notch sits at 6h, not 8h.
    func testFamilyDayShortensOnlyItsOwnTarget() {
        let days = summary().days
        XCTAssertEqual(days[0].target, 8 * 3600)
        XCTAssertEqual(days[4].target, 6 * 3600)
    }

    func testTimeOffShortensThatDaysTarget() {
        var data = week
        data.timeOff = [Calendar.current.startOfDay(for: d(2026, 7, 29, 0, 0)): 2.0 * 3600]
        XCTAssertEqual(summary(data).days[2].target, 6 * 3600)
    }

    /// The property that lets the rows sit under the total without contradicting
    /// it, on an ordinary week. Short days floor at zero, exactly as weeklyOvertime
    /// counts them. `testPostLunchClockInStillAgreesWithTheTotal` is the case that
    /// actually stresses it.
    func testPerDayOvertimeSumsToTheWeeklyTotal() {
        let s = summary()
        XCTAssertEqual(s.days.map(\.overtime), [35.0 * 60, 70.0 * 60, 0, 0, 0])
        XCTAssertEqual(s.days.reduce(0) { $0 + $1.overtime }, s.overtime)
        XCTAssertEqual(s.overtime, 105 * 60)
        XCTAssertEqual(s.cap, rules.weeklyOvertimeCap)
    }

    func testTargetNoteReflectsToday() {
        XCTAssertEqual(summary().targetNote, "Target 6:00 · family day")
        // Wednesday is ordinary, so a Wednesday `now` has nothing to explain.
        XCTAssertNil(summary(now: d(2026, 7, 29, 15, 0)).targetNote)
    }

    func testTodayIsDayOffTracksTheDayOffSet() {
        XCTAssertFalse(summary().todayIsDayOff)
        XCTAssertTrue(summary(now: d(2026, 7, 30, 10, 0)).todayIsDayOff)
    }

    /// Regression test for a defect the plan originally shipped: deriving the row's
    /// overtime from `worked - target` diverges from the published total whenever the
    /// worker clocked in after lunch, because `breakTaken` is 0 while `leaveTime`
    /// still adds the whole break. 13:00 start, 8h target, due out 22:00; at 22:30 the
    /// naive form gives +1:30 and the total gives +0:30. They must agree.
    func testPostLunchClockInStillAgreesWithTheTotal() {
        let data = WeekData(records: [
            WorkRecord(clockIn: d(2026, 7, 29, 13, 0), clockOut: nil, flexWorkedNet: nil)
        ])
        let s = WeekSummary.compute(from: data, now: d(2026, 7, 29, 22, 30), rules: rules)
        XCTAssertEqual(s.days[2].overtime, 30 * 60)
        XCTAssertEqual(s.days[2].overtime, s.overtime)
        // The bar still measures actual time on the clock, break untaken.
        XCTAssertEqual(s.days[2].worked, 9 * 3600 + 30 * 60)
    }

    /// Pins the one accepted gap in "the rows sum to the total", so that it cannot
    /// change without a red test. **The divergence below is intentional.** Weekends are
    /// deliberately not modelled (five fixed rows, Mon–Fri), but `weeklyOvertime` counts
    /// every record in the week, so a Saturday record contributes to the total and gets
    /// no row: the rows sum to 0 while the total reads 1h.
    ///
    /// If you are here because this test failed, the assertion is not the bug. Either
    /// weekend rows were added — in which case rewrite this to expect six or seven rows
    /// — or weekend records were filtered out of the total, which would make the popover
    /// disagree with the menu bar pill and is a spec change, not a fix.
    ///
    /// Sat 2026-08-01 09:00–19:00 is 10h gross, less the 1h break = 9h net against an
    /// ordinary 8h target (Saturday is not a family day), so +1:00.
    func testWeekendRecordCountsInTheTotalButHasNoRow() {
        let data = WeekData(records: [
            WorkRecord(clockIn: d(2026, 8, 1, 9, 0), clockOut: d(2026, 8, 1, 19, 0),
                       flexWorkedNet: nil)
        ])
        let s = WeekSummary.compute(from: data, now: d(2026, 8, 1, 19, 30), rules: rules)
        // Still five weekday rows, and every one of them empty.
        XCTAssertEqual(s.days.count, 5)
        XCTAssertTrue(s.days.allSatisfy { $0.worked == nil })
        XCTAssertEqual(s.days.reduce(0) { $0 + $1.overtime }, 0)
        // ...while the total carries the Saturday hour. This is the divergence.
        XCTAssertEqual(s.overtime, 60 * 60)
        // A weekend `now` matches no row, so nothing claims today is a day off.
        XCTAssertFalse(s.todayIsDayOff)
    }

    /// A manual start is a real record everywhere else, so it must appear as a row.
    func testManualStartAppearsAsARow() {
        SettingsStore.setManualStart(d(2026, 7, 31, 9, 12), on: d(2026, 7, 31, 9, 12))
        let s = WeekSummary.compute(from: WeekData(), now: now, rules: rules)
        XCTAssertEqual(s.days[4].worked, 4 * 3600 + 29 * 60)
        XCTAssertTrue(s.days[4].isOngoing)
    }
}
