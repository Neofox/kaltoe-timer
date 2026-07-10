import XCTest
@testable import FlexTimer

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

    func testWeeklyOvertimeCanonical() {
        // Spec canonical: only Monday 09:01–20:02 worked so far → −5h + 2h01 = −2h59
        let mon = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [mon], now: d(2026, 7, 6, 23, 0), rules: rules),
                       -(2 * 3600 + 59 * 60))
    }

    func testWeeklyOvertimeEmptyWeek() {
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [], now: d(2026, 7, 6, 9, 0), rules: rules),
                       -5 * 3600)
    }

    func testWeeklyOvertimeMixedWeek() {
        // Mon +2h01, Tue −1h, Wed open past leave by 10m → −5h + 2h01 − 1h + 10m = −3h49
        let mon = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil)
        let tue = WorkRecord(clockIn: d(2026, 7, 7, 9, 0), clockOut: d(2026, 7, 7, 17, 0), flexWorkedNet: nil)
        let wed = WorkRecord(clockIn: d(2026, 7, 8, 9, 0), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [mon, tue, wed],
                                                     now: d(2026, 7, 8, 18, 10), rules: rules),
                       -(3 * 3600 + 49 * 60))
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

    // MARK: - Adjusted weekly requirement

    func testRequiredOvertimePlainWeek() {
        // Week of Mon 2026-07-06: no day-offs, no family day → 5h
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       5 * 3600)
    }

    func testRequiredOvertimeDeductsPerDayOff() {
        let thu = Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))
        let fri = Calendar.current.startOfDay(for: d(2026, 7, 10, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [thu], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       4 * 3600)
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [thu, fri], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       3 * 3600)
    }

    func testRequiredOvertimeIgnoresDayOffsOutsideWeek() {
        let prevWeek = Calendar.current.startOfDay(for: d(2026, 7, 2, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [prevWeek], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       5 * 3600)
    }

    func testRequiredOvertimeFamilyDayWeek() {
        // Week of Mon 2026-07-27 contains family day Fri 2026-07-31 → 5 − 1 = 4h
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [], weekOf: d(2026, 7, 29, 12, 0), rules: rules),
                       4 * 3600)
    }

    func testFamilyDayVacationCoincidenceDeductsOnce() {
        // Vacation ON family day: family-day −1h applies, day-off count excludes it → 4h, not 3h
        let familyFriday = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [familyFriday], weekOf: d(2026, 7, 29, 12, 0), rules: rules),
                       4 * 3600)
    }

    func testRequiredOvertimeFloorsAtZero() {
        let days = (6...10).map { Calendar.current.startOfDay(for: d(2026, 7, $0, 0, 0)) }
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: Set(days), weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       0)
    }

    func testWeeklyOvertimeUsesAdjustedRequirement() {
        // One day-off Thursday, no records yet → counter = −4:00
        let thu = Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [], dayOffs: [thu],
                                                     now: d(2026, 7, 8, 12, 0), rules: rules),
                       -4 * 3600)
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
                                                    timeOff: [friday: 4 * 3600]),
                       -(1 * 3600 + 25 * 60))
    }

    func testCompletedHalfDayFallbackNetSkipsBreak() {
        // No flexWorkedNet: net = gross (no break at ≤4h target). 09:00–12:30 = 3h30m vs 4h → −30m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 9, 0), clockOut: d(2026, 1, 2, 12, 30), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 23, 0), rules: rules,
                                                    timeOff: [friday: 4 * 3600]),
                       -30 * 60)
    }

    func testOpenHalfDayAccruesAfterReducedLeaveTime() {
        // Leave 12:55; still on the clock at 13:25 → +30m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 13, 25), rules: rules,
                                                    timeOff: [friday: 4 * 3600]),
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
        XCTAssertEqual(WorkCalculator.timeOff(on: d(2026, 1, 2, 14, 33), in: [friday: 4 * 3600]),
                       4 * 3600)
        XCTAssertEqual(WorkCalculator.timeOff(on: d(2026, 1, 3, 14, 33), in: [friday: 4 * 3600]), 0)
    }
}
