import XCTest
@testable import FlexTimer

final class FormattingTests: XCTestCase {
    func testHM() {
        XCTAssertEqual(Formatting.hm(2 * 3600 + 34 * 60 + 59), "2:34") // floors seconds
        XCTAssertEqual(Formatting.hm(5 * 60), "0:05")
        XCTAssertEqual(Formatting.hm(-30), "0:00")
    }

    func testSignedHM() {
        XCTAssertEqual(Formatting.signedHM(-(2 * 3600 + 59 * 60)), "-2:59")
        XCTAssertEqual(Formatting.signedHM(12 * 60), "+0:12")
        XCTAssertEqual(Formatting.signedHM(0), "+0:00")
    }

    func testSignedHMNearZeroNegativeFloorsToPlusZero() {
        XCTAssertEqual(Formatting.signedHM(-30), "+0:00")
        XCTAssertEqual(Formatting.signedHM(-59), "+0:00")
        XCTAssertEqual(Formatting.signedHM(-60), "-0:01")
    }

    func testHMS() {
        XCTAssertEqual(Formatting.hms(2 * 3600 + 34 * 60 + 12), "2:34:12")
    }
}

final class DisplayStateTests: XCTestCase {
    let rules = WorkRules()

    func testNoSession() {
        XCTAssertEqual(DisplayState.compute(hasSession: false, today: nil, week: [],
                                            now: d(2026, 7, 6, 9, 0), rules: rules), .noSession)
        XCTAssertEqual(DisplayState.noSession.menuBarText, "—")
    }

    func testNotClockedIn() {
        XCTAssertEqual(DisplayState.compute(hasSession: true, today: nil, week: [],
                                            now: d(2026, 7, 6, 8, 0), rules: rules), .notClockedIn)
        XCTAssertEqual(DisplayState.notClockedIn.menuBarText, "--:--")
    }

    func testCountingDuringDay() {
        let today = WorkRecord(clockIn: d(2026, 7, 6, 8, 59), clockOut: nil, flexWorkedNet: nil)
        let s = DisplayState.compute(hasSession: true, today: today, week: [today],
                                     now: d(2026, 7, 6, 15, 25), rules: rules)
        XCTAssertEqual(s, .counting(timeLeft: 2 * 3600 + 34 * 60))
        XCTAssertEqual(s.menuBarText, "2:34")
    }

    func testOvertimeAfterLeaveTime() {
        // Spec canonical Monday evening: shows OT -2:59
        let today = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: nil, flexWorkedNet: nil)
        let s = DisplayState.compute(hasSession: true, today: today, week: [today],
                                     now: d(2026, 7, 6, 20, 2), rules: rules)
        XCTAssertEqual(s, .overtime(weekly: -(2 * 3600 + 59 * 60)))
        XCTAssertEqual(s.menuBarText, "OT -2:59")
    }

    func testOvertimeAfterClockingOutEarly() {
        // Already clocked out → show weekly OT even if before leave time
        let today = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 16, 0), flexWorkedNet: nil)
        let s = DisplayState.compute(hasSession: true, today: today, week: [today],
                                     now: d(2026, 7, 6, 16, 5), rules: rules)
        XCTAssertEqual(s, .overtime(weekly: -7 * 3600))
    }
}

final class PhaseDisplayTests: XCTestCase {
    let rules = WorkRules()
    var seoul: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }

    func display(_ clockIn: Date, _ now: Date, clockOut: Date? = nil,
                 r: WorkRules? = nil) -> MenuDisplay {
        let today = WorkRecord(clockIn: clockIn, clockOut: clockOut, flexWorkedNet: nil)
        return DisplayState.computeDisplay(hasSession: true, today: today, week: [today],
                                           now: now, rules: r ?? rules, calendar: seoul)
    }

    // Phase boundaries: clock-in 09:00 → lunch-leave 11:20, lunch-end 12:30, leave 18:00
    func testMorningCountsDownToLunchLeave() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 9, 30))
        XCTAssertEqual(s, MenuDisplay(state: .toLunch(timeLeft: 6600), urgency: .normal)) // 1h50 to 11:20
        XCTAssertEqual(s.state.menuBarText, "1:50")
        XCTAssertEqual(s.state.iconName, "fork.knife")
    }

    func testBoundary1119IsToLunch() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 19)).state,
                       .toLunch(timeLeft: 60))
    }

    func testBoundary1120IsOnBreak() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 20))
        XCTAssertEqual(s, MenuDisplay(state: .onBreak(timeLeft: 4200), urgency: .normal)) // 1:10 to 12:30
        XCTAssertEqual(s.state.menuBarText, "BREAK 1:10")
        XCTAssertEqual(s.state.iconName, "cup.and.saucer")
    }

    func testBoundary1229IsOnBreak() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 12, 29)).state,
                       .onBreak(timeLeft: 60))
    }

    func testBoundary1230IsCounting() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 12, 30)).state,
                       .counting(timeLeft: 5 * 3600 + 30 * 60)) // to 18:00
    }

    func testLateClockInDuringLunchIsOnBreak() {
        XCTAssertEqual(display(d(2026, 7, 9, 11, 25), d(2026, 7, 9, 11, 26)).state,
                       .onBreak(timeLeft: 64 * 60))
    }

    func testAfternoonClockInSkipsLunchPhases() {
        XCTAssertEqual(display(d(2026, 7, 9, 13, 0), d(2026, 7, 9, 14, 0)).state,
                       .counting(timeLeft: 8 * 3600)) // leave 22:00
    }

    func testDegenerateEarlyDaySkipsLunchPhases() {
        // clock-in 02:00 → leave 11:00 ≤ lunch end 12:30 → no lunch phases
        XCTAssertEqual(display(d(2026, 7, 9, 2, 0), d(2026, 7, 9, 9, 0)).state,
                       .counting(timeLeft: 2 * 3600))
    }

    func testCustomLunchRulesShiftBoundaries() {
        var r = WorkRules()
        r.lunchStart = 12 * 3600; r.lunchEnd = 13 * 3600; r.lunchEarlyLeave = 0
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 30), r: r).state,
                       .toLunch(timeLeft: 30 * 60))
    }

    // Urgency: leave 18:00
    func testUrgencySteps() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 29)).urgency, .normal)   // 31 min
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 30)).urgency, .warning)  // 30 min
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 50)).urgency, .critical) // 10 min
    }

    func testPastLeaveStillClockedInIsCritical() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 18, 5))
        XCTAssertEqual(s.urgency, .critical)
        if case .overtime = s.state {} else { XCTFail("expected overtime state") }
    }

    func testClockedOutOvertimeIsNormal() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 18, 10), clockOut: d(2026, 7, 9, 18, 5))
        XCTAssertEqual(s.urgency, .normal)
        if case .overtime = s.state {} else { XCTFail("expected overtime state") }
    }

    func testNoSessionAndNotClockedInAreNormalWithTimerIcon() {
        let none = DisplayState.computeDisplay(hasSession: false, today: nil, week: [],
                                               now: d(2026, 7, 9, 9, 0), rules: rules, calendar: seoul)
        XCTAssertEqual(none, MenuDisplay(state: .noSession, urgency: .normal))
        XCTAssertEqual(DisplayState.counting(timeLeft: 60).iconName, "timer")
        XCTAssertEqual(DisplayState.overtime(weekly: 0).iconName, "timer")
        XCTAssertEqual(DisplayState.noSession.iconName, "timer")
        XCTAssertEqual(DisplayState.notClockedIn.iconName, "timer")
    }
}
