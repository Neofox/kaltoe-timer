import XCTest
@testable import KaltoeCore

/// Date in Asia/Seoul, gregorian.
func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
}

let rules = WorkRules()

final class WorkCalculatorTests: XCTestCase {
    // Spec canonical: clock in 08:59 → leave 17:59 (start + 8h work + 1h break)
    func testLeaveTime() {
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 6, 8, 59), rules: rules),
                       d(2026, 7, 6, 17, 59))
    }

    func testTimeLeftMidDay() {
        // at 14:27, 3h32m left until 17:59
        XCTAssertEqual(WorkCalculator.timeLeft(clockIn: d(2026, 7, 6, 8, 59),
                                               now: d(2026, 7, 6, 14, 27), rules: rules),
                       3 * 3600 + 32 * 60)
    }

    func testDailyOvertimeCompletedDay() {
        // Spec canonical: Mon 09:01–20:02 → 11h01 gross − 1h break − 8h target = +2h01
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       2 * 3600 + 60)
    }

    func testDailyOvertimeEarlyLeaveIsNegative() {
        // 09:00–16:00 → 6h net → −2h
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 16, 0), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       -2 * 3600)
    }

    func testDailyOvertimeOpenDayBeforeLeaveTimeIsZero() {
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 14, 0), rules: rules), 0)
    }

    func testDailyOvertimeOpenDayAccruesLiveAfterLeaveTime() {
        // leave time 18:01; at 18:31 → +30min
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 18, 31), rules: rules),
                       30 * 60)
    }

    func testFlexReportedNetWinsOverStamps() {
        // Flex says 9h net worked → +1h regardless of stamps
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 10, 0),
                           flexWorkedNet: 9 * 3600)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       1 * 3600)
    }

    func testVeryShortCompletedDayClampsNetAtZero() {
        // 09:00–09:30 gross 30m < 1h break → net 0 → −8h, not −8h30
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 9, 30), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       -8 * 3600)
    }

    func testWeekStartIsMondayMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        // Thu 2026-07-09 → Mon 2026-07-06 00:00
        XCTAssertEqual(WorkCalculator.weekStart(of: d(2026, 7, 9, 14, 0), calendar: cal), d(2026, 7, 6, 0, 0))
        // A Monday maps to itself
        XCTAssertEqual(WorkCalculator.weekStart(of: d(2026, 7, 6, 0, 30), calendar: cal), d(2026, 7, 6, 0, 0))
        // Sunday belongs to the week started the previous Monday
        XCTAssertEqual(WorkCalculator.weekStart(of: d(2026, 7, 12, 23, 0), calendar: cal), d(2026, 7, 6, 0, 0))
    }

    func testLunchWindowDefaults() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let window = WorkCalculator.lunchWindow(on: d(2026, 7, 9, 14, 0), rules: rules, calendar: cal)
        XCTAssertEqual(window.leaveAt, d(2026, 7, 9, 11, 20)) // 11:30 − 10 min allowance
        XCTAssertEqual(window.endAt, d(2026, 7, 9, 12, 30))
    }

    func testLunchWindowCustomRules() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var r = WorkRules()
        r.lunchStart = 12 * 3600      // 12:00
        r.lunchEnd = 13 * 3600        // 13:00
        r.lunchEarlyLeave = 0
        let window = WorkCalculator.lunchWindow(on: d(2026, 7, 9, 9, 0), rules: r, calendar: cal)
        XCTAssertEqual(window.leaveAt, d(2026, 7, 9, 12, 0))
        XCTAssertEqual(window.endAt, d(2026, 7, 9, 13, 0))
    }

    // MARK: - Family day

    func testIsFamilyDayLastFridayOnly() {
        XCTAssertTrue(WorkCalculator.isFamilyDay(d(2026, 7, 31, 12, 0)))   // last Friday of July
        XCTAssertTrue(WorkCalculator.isFamilyDay(d(2026, 8, 28, 12, 0)))   // last Friday of August
        XCTAssertFalse(WorkCalculator.isFamilyDay(d(2026, 7, 24, 12, 0)))  // Friday, not last
        XCTAssertFalse(WorkCalculator.isFamilyDay(d(2026, 7, 30, 12, 0)))  // Thursday before it
    }

    func testFamilyDayLeaveTimeIsTwoHoursEarlier() {
        // 09:00 + 6h target + 1h break = 16:00 on family day
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: rules),
                       d(2026, 7, 31, 16, 0))
        // familyDayEarlyLeave = 0 disables it: 09:00 + 8h + 1h = 18:00
        var noFamily = rules
        noFamily.familyDayEarlyLeave = 0
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: noFamily),
                       d(2026, 7, 31, 18, 0))
    }

    func testFamilyDayEarlyLeaveIsFree() {
        // In 09:00, out 16:00 → 7h gross − 1h break = 6h net = family-day target → 0 overtime
        let r = WorkRecord(clockIn: d(2026, 7, 31, 9, 0), clockOut: d(2026, 7, 31, 16, 0), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 31, 23, 0), rules: rules), 0)
    }

    func testFamilyDayOpenRecordAccruesAfterEarlyLeaveTime() {
        // Still clocked in at 16:30 on family day (leave was 16:00) → +30 min
        let r = WorkRecord(clockIn: d(2026, 7, 31, 9, 0), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 31, 16, 30), rules: rules),
                       30 * 60)
    }

    // MARK: - Time off (half/full-day leave)

    func testHalfDayLeaveTimeHasNoLunchBreak() {
        // 4h off → 4h target → 08:55 + 4h, no break (reduced target ≤ dailyWork/2)
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 1, 2, 8, 55), rules: rules,
                                                timeOff: 4 * 3600),
                       d(2026, 1, 2, 12, 55))
    }

    func testSmallTimeOffKeepsLunchBreak() {
        // 2h off → 6h target > 4h → break stays: 09:00 + 6h + 1h = 16:00
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 6, 9, 0), rules: rules,
                                                timeOff: 2 * 3600),
                       d(2026, 7, 6, 16, 0))
    }

    func testCompletedHalfDayOvertimeAgainstReducedTarget() {
        // Net 2h35m (from Flex) vs 4h target → −1h25m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: d(2026, 1, 2, 12, 30),
                           flexWorkedNet: 2 * 3600 + 35 * 60)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 23, 0), rules: rules,
                                                    timeOff: [friday: 4.0 * 3600]),
                       -(1 * 3600 + 25 * 60))
    }

    func testCompletedHalfDayFallbackNetSkipsBreak() {
        // No flexWorkedNet: net = gross (no break at ≤4h target). 09:00–12:30 = 3h30m vs 4h → −30m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 9, 0), clockOut: d(2026, 1, 2, 12, 30), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 23, 0), rules: rules,
                                                    timeOff: [friday: 4.0 * 3600]),
                       -30 * 60)
    }

    func testOpenHalfDayAccruesAfterReducedLeaveTime() {
        // Leave 12:55; still on the clock at 13:25 → +30m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 13, 25), rules: rules,
                                                    timeOff: [friday: 4.0 * 3600]),
                       30 * 60)
    }

    func testFamilyDayPlusTimeOffStacksAndFloorsAtZero() {
        // Family day 2026-07-31: 8h − 2h family − 4h off = 2h target; 09:00 + 2h = 11:00, no break
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: rules,
                                                timeOff: 4 * 3600),
                       d(2026, 7, 31, 11, 0))
        // 8h off on family day → floor at 0 target → leave = clockIn
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: rules,
                                                timeOff: 8 * 3600),
                       d(2026, 7, 31, 9, 0))
    }

    func testTimeOffLookupNormalizesToStartOfDay() {
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        XCTAssertEqual(WorkCalculator.timeOff(on: d(2026, 1, 2, 14, 33), in: [friday: 4.0 * 3600]),
                       4 * 3600)
        XCTAssertEqual(WorkCalculator.timeOff(on: d(2026, 1, 3, 14, 33), in: [friday: 4.0 * 3600]), 0)
    }

    func testWeeklyOvertimeThreadsTimeOffThroughDailySum() {
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        // Half-day Fri completed with net 2h35m vs the time-off-reduced 4h target
        // → −1h25m, which the gross weekly sum floors to 0.
        let short = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: d(2026, 1, 2, 12, 30),
                               flexWorkedNet: 2 * 3600 + 35 * 60)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [short], timeOff: [friday: 4.0 * 3600],
                                                     now: d(2026, 1, 2, 23, 0), rules: rules),
                       0)
        // Net 5h against the same 4h target → +1h. Were the time off not threaded
        // through, this would score 5h − 8h = −3h and floor to 0 like the case
        // above — so the positive result is what proves the threading.
        let long = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: d(2026, 1, 2, 13, 55),
                              flexWorkedNet: 5 * 3600)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [long], timeOff: [friday: 4.0 * 3600],
                                                     now: d(2026, 1, 2, 23, 0), rules: rules),
                       1 * 3600)
    }

    private var seoul: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    func testIsPastOvertimeCutoffAtBoundary() {
        let rules = WorkRules()  // 22:00
        XCTAssertFalse(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 21, 59), rules: rules, calendar: seoul))
        XCTAssertTrue(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 22, 0), rules: rules, calendar: seoul))
        XCTAssertTrue(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 23, 30), rules: rules, calendar: seoul))
    }

    func testIsPastOvertimeCutoffRespectsCustomCutoff() {
        var rules = WorkRules()
        rules.overtimeCutoff = 20 * 3600  // 20:00
        XCTAssertFalse(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 19, 59), rules: rules, calendar: seoul))
        XCTAssertTrue(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 20, 0), rules: rules, calendar: seoul))
    }

    func testHasReachedWeeklyCapAtBoundary() {
        let rules = WorkRules()  // 12h
        XCTAssertFalse(WorkCalculator.hasReachedWeeklyCap(
            weeklyOvertime: 11 * 3600 + 3599, rules: rules))
        XCTAssertTrue(WorkCalculator.hasReachedWeeklyCap(
            weeklyOvertime: 12 * 3600, rules: rules))
        XCTAssertTrue(WorkCalculator.hasReachedWeeklyCap(
            weeklyOvertime: 20 * 3600, rules: rules))
    }

    // MARK: - Gross weekly sum

    /// A short day has no hours *over* the target, so it contributes zero — it
    /// must not offset a long day. Under the old net-against-quota model these
    /// two days cancelled to 0; under the cap model the week is +1h.
    func testWeeklyOvertimeShortDayContributesZero() {
        let rules = WorkRules()
        let now = d(2026, 7, 31, 18, 0)
        // 09:00-19:00 = 10h elapsed - 1h lunch = 9h net = +1h overtime
        let long = WorkRecord(clockIn: d(2026, 7, 27, 9, 0),
                              clockOut: d(2026, 7, 27, 19, 0), flexWorkedNet: nil)
        // 09:00-17:00 = 8h elapsed - 1h lunch = 7h net = -1h, floored to 0
        let short = WorkRecord(clockIn: d(2026, 7, 28, 9, 0),
                               clockOut: d(2026, 7, 28, 17, 0), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [long, short],
                                                     now: now, rules: rules),
                       3600, accuracy: 1)
    }

    func testWeeklyOvertimeEmptyWeekIsZero() {
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [],
                                                     now: d(2026, 7, 31, 18, 0),
                                                     rules: WorkRules()),
                       0, accuracy: 1)
    }

    func testWeeklyOvertimeSumsTwoLongDays() {
        let rules = WorkRules()
        let now = d(2026, 7, 31, 18, 0)
        let a = WorkRecord(clockIn: d(2026, 7, 27, 9, 0),
                           clockOut: d(2026, 7, 27, 19, 0), flexWorkedNet: nil)   // +1h
        let b = WorkRecord(clockIn: d(2026, 7, 28, 9, 0),
                           clockOut: d(2026, 7, 28, 20, 30), flexWorkedNet: nil)  // +2h30
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [a, b],
                                                     now: now, rules: rules),
                       3600 + 9000, accuracy: 1)
    }

    // MARK: breakTaken

    func testBreakTakenIsZeroBeforeLunchStarts() {
        // Clocked in 09:12, now 10:00 — the 11:30 lunch has not begun.
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 10, 0), rules: rules), 0)
    }

    func testBreakTakenAccruesDuringLunch() {
        // Lunch runs 11:30–12:30. At 12:00, half of it is spent.
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 12, 0), rules: rules),
                       30 * 60)
    }

    func testBreakTakenCapsAtTheFullBreakAfterLunch() {
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 16, 0), rules: rules),
                       3600)
    }

    /// Clocking in after lunch never consumed it, so nothing is deducted — this is
    /// the case a naive `now − lunchStart` would get wrong.
    func testBreakTakenIsZeroWhenClockingInAfterLunch() {
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 13, 0),
                                                 now: d(2026, 7, 31, 18, 0), rules: rules), 0)
    }

    /// A half-day target has no break at all (breakDuration returns 0), so there is
    /// none to consume even long after the lunch window.
    func testBreakTakenIsZeroWhenTheDayHasNoBreak() {
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 29, 9, 0),
                                                 now: d(2026, 7, 29, 18, 0), rules: rules,
                                                 timeOff: 4 * 3600), 0)
    }

    /// The cap is the day's break, not the window's width: a 30-minute break inside
    /// a 60-minute window stops at 30.
    func testBreakTakenCapsAtTheBreakNotTheWindow() {
        var short = WorkRules()
        short.breakTime = 30 * 60
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 16, 0), rules: short),
                       30 * 60)
    }

    // MARK: dayProgress

    // Canonical day: clock in 08:59 → leave 17:59, a 9h span (8h target + 1h break).
    // 13:29 is 4h30 in, exactly half.
    func testDayProgressIsHalfwayAtMidSpan() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 13, 29), rules: rules),
                       0.5, accuracy: 0.0001)
    }

    /// The denominator is the whole clock-in→leave span, not the 8h target. Dividing
    /// by the target alone would read 1.0 here, an hour before you may leave.
    func testDayProgressAtTargetButNotLeaveTimeIsNotComplete() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 16, 59), rules: rules),
                       8.0 / 9.0, accuracy: 0.0001)
    }

    func testDayProgressIsZeroAtClockIn() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 8, 59), rules: rules), 0)
    }

    func testDayProgressClampsBeforeClockInAndPastLeaveTime() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 7, 0), rules: rules), 0)
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 23, 0), rules: rules), 1)
    }

    /// Family day (last Friday of the month) cuts the target to 6h; the break
    /// survives because 6h is still over half a day, so the span is 7h. 12:30 is
    /// 3h30 in.
    func testDayProgressUsesTheFamilyDayShortenedSpan() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 31, 9, 0),
                                                 now: d(2026, 7, 31, 12, 30), rules: rules),
                       0.5, accuracy: 0.0001)
    }

    /// 4h of time off drops the target to 4h, which is *not* over half a day, so
    /// `breakDuration` yields no lunch and the span is 4h — not 5h. Deriving the
    /// span from `leaveTime` is what inherits that rule.
    func testDayProgressLosesTheBreakOnAHalfDay() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 11, 0), rules: rules,
                                                 timeOff: 4 * 3600),
                       0.5, accuracy: 0.0001)
    }

    /// Hostile settings reach here through `SettingsStore.rules`. A zero span
    /// would divide to ±inf and a non-finite target to NaN; both must yield 0,
    /// because the renderer may never see one.
    func testDayProgressIsZeroWhenTheSpanCollapses() {
        var zero = rules
        zero.dailyWork = 0
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 14, 0), rules: zero), 0)
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 14, 0), rules: rules,
                                                 timeOff: 8 * 3600), 0)
    }

    func testDayProgressIsZeroForANonFiniteTarget() {
        var wild = rules
        wild.dailyWork = .infinity
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 14, 0), rules: wild), 0)
    }
    // MARK: isWeekend

    /// Gregorian weekday numbering is 1 = Sunday … 7 = Saturday, so the weekday range
    /// is 2...6. Injected calendar, because the boundary is exactly where a
    /// host-timezone shift would move the answer.
    func testIsWeekendAcrossTheBoundary() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertFalse(WorkCalculator.isWeekend(d(2026, 7, 31, 12, 0), calendar: cal)) // Fri
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 1, 12, 0), calendar: cal))   // Sat
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 2, 12, 0), calendar: cal))   // Sun
        XCTAssertFalse(WorkCalculator.isWeekend(d(2026, 8, 3, 12, 0), calendar: cal))  // Mon
    }

    /// Midnight and one minute to midnight on the same Saturday, so a naive
    /// hour-of-day mistake cannot pass.
    func testIsWeekendHoldsAcrossTheWholeDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 1, 0, 0), calendar: cal))
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 1, 23, 59), calendar: cal))
    }
}
