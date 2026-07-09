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
}
