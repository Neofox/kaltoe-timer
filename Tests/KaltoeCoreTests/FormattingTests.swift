import XCTest
@testable import KaltoeCore

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

    /// `Int(Double)` traps on NaN and on the infinities, and all three formatters reach
    /// it before any clamping. Not theoretical: `weeklyOvertimeCapHours` is a documented
    /// `defaults write` knob, and `MenuBarView` passes the cap straight into `hm`, so
    /// `-float nan` crash-looped the popover on input `StatusLine` already survived.
    func testFormattersSurviveNonFiniteInput() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(Formatting.hm(bad), "0:00", "hm(\(bad))")
            XCTAssertEqual(Formatting.hms(bad), "0:00:00", "hms(\(bad))")
            XCTAssertEqual(Formatting.signedHM(bad), "+0:00", "signedHM(\(bad))")
        }
    }
}

final class DisplayStateTests: XCTestCase {
    let rules = WorkRules()
    var seoul: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }

    func testNoSession() {
        XCTAssertEqual(DisplayState.computeDisplay(hasSession: false, today: nil,
                                                   weeklyOvertime: 0,
                                                   now: d(2026, 7, 6, 9, 0), rules: rules).state,
                       .noSession)
        XCTAssertEqual(DisplayState.noSession.menuBarText, "—")
    }

    func testNotClockedIn() {
        XCTAssertEqual(DisplayState.computeDisplay(hasSession: true, today: nil,
                                                   weeklyOvertime: 0,
                                                   now: d(2026, 7, 6, 8, 0), rules: rules).state,
                       .notClockedIn)
        XCTAssertEqual(DisplayState.notClockedIn.menuBarText, "--:--")
    }

    func testCountingDuringDay() {
        let today = WorkRecord(clockIn: d(2026, 7, 6, 8, 59), clockOut: nil, flexWorkedNet: nil)
        let s = DisplayState.computeDisplay(hasSession: true, today: today,
                                            weeklyOvertime: 0,
                                            now: d(2026, 7, 6, 15, 25), rules: rules).state
        XCTAssertEqual(s, .counting(timeLeft: 2 * 3600 + 34 * 60))
        XCTAssertEqual(s.menuBarText, "2:34")
    }

    /// Still on the clock an hour past leave time: the menu bar shows today's
    /// overtime, not the week's, and overtime alone is only a warning.
    func testOvertimePastLeaveTimeShowsTodayAndWarns() {
        let rules = WorkRules()
        let today = WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  weeklyOvertime: 3600,
                                                  now: d(2026, 7, 29, 19, 0),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.state, .overtime(today: 3600, clockedIn: true))
        XCTAssertEqual(display.state.menuBarText, "OT +1:00")
        XCTAssertEqual(display.urgency, .warning)
    }

    /// Clocked out short of target: today's figure is negative and the day is
    /// settled, so nothing is urgent.
    func testOvertimeClockedOutEarlyShowsNegativeAndIsNormal() {
        let rules = WorkRules()
        let today = WorkRecord(clockIn: d(2026, 7, 29, 9, 0),
                               clockOut: d(2026, 7, 29, 17, 0), flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  weeklyOvertime: 0,
                                                  now: d(2026, 7, 29, 17, 30),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.state, .overtime(today: -3600, clockedIn: false))
        XCTAssertEqual(display.state.menuBarText, "OT -1:00")
        XCTAssertEqual(display.urgency, .normal)
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
                 r: WorkRules? = nil, weeklyOvertime: TimeInterval = 0) -> MenuDisplay {
        let today = WorkRecord(clockIn: clockIn, clockOut: clockOut, flexWorkedNet: nil)
        return DisplayState.computeDisplay(hasSession: true, today: today,
                                           weeklyOvertime: weeklyOvertime,
                                           now: now, rules: r ?? rules, calendar: seoul)
    }

    // Phase boundaries: clock-in 09:00 → lunch-leave 11:20, lunch-end 12:30, leave 18:00
    func testMorningCountsDownToLunchLeave() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 9, 30))
        // 1h50 to 11:20, and 30 of the morning's 140 minutes spent.
        XCTAssertEqual(s, MenuDisplay(state: .toLunch(timeLeft: 6600), urgency: .normal,
                                      fillProgress: 30.0 / 140))
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

    // MARK: fillProgress — the ring measures the number beside it

    /// The invariant the whole thing exists for: whatever the label is counting down
    /// to, the ring is full when that countdown reaches zero. Checked at the last
    /// minute of each of the three working phases, on the canonical 09:00 day.
    ///
    /// Without this the morning silently reverts to `dayProgress`, where 11:19 reads
    /// 0.26 — a nearly-empty ring beside "0:01".
    func testFillIsFullAsEachCountdownExpires() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 19)).fillProgress,
                       139.0 / 140, accuracy: 0.001)   // one minute to lunch
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 12, 29)).fillProgress,
                       69.0 / 70, accuracy: 0.001)     // one minute of break left
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 59)).fillProgress,
                       329.0 / 330, accuracy: 0.001)   // one minute to leave
    }

    /// Each phase restarts from empty, so the arc is never a leftover of the last one.
    func testFillRestartsAtEachPhaseBoundary() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 9, 0)).fillProgress, 0)
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 20)).fillProgress, 0)
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 12, 30)).fillProgress, 0)
    }

    /// The morning and afternoon fills are the segment's, not the day's — stated
    /// against `dayProgress` at the same instants, which is what they used to be and
    /// what they must no longer equal.
    func testFillMeasuresTheSegmentAndNotTheDay() {
        let clockIn = d(2026, 7, 9, 9, 0)
        let morning = d(2026, 7, 9, 10, 0)
        XCTAssertEqual(display(clockIn, morning).fillProgress, 60.0 / 140, accuracy: 0.001)
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: clockIn, now: morning, rules: rules),
                       60.0 / 540, accuracy: 0.001)

        // 12:30→18:00 is 330 minutes; 15:00 is 150 of them in.
        let afternoon = d(2026, 7, 9, 15, 0)
        XCTAssertEqual(display(clockIn, afternoon).fillProgress, 150.0 / 330, accuracy: 0.001)
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: clockIn, now: afternoon, rules: rules),
                       360.0 / 540, accuracy: 0.001)
    }

    /// Clocking in at 11:25, mid-window, starts the break arc from *then* rather than
    /// from a 11:20 departure that never happened.
    func testBreakFillStartsFromClockInWhenItLandsMidWindow() {
        XCTAssertEqual(display(d(2026, 7, 9, 11, 25), d(2026, 7, 9, 11, 30)).fillProgress,
                       5.0 / 65, accuracy: 0.001)
    }

    /// A day with no lunch phase has exactly one segment, so the fill is the day's
    /// progress again — the afternoon branch must not subtract a break that never
    /// applied. Clock-in 02:00 → leave 11:00, and 13:00 → leave 22:00.
    func testDaysWithoutALunchPhaseFillAcrossTheWholeDay() {
        for (clockIn, now, expected) in [(d(2026, 7, 9, 2, 0), d(2026, 7, 9, 9, 0), 7.0 / 9),
                                         (d(2026, 7, 9, 13, 0), d(2026, 7, 9, 14, 0), 1.0 / 9)] {
            XCTAssertEqual(display(clockIn, now).fillProgress, expected, accuracy: 0.001)
            XCTAssertEqual(display(clockIn, now).fillProgress,
                           WorkCalculator.dayProgress(clockIn: clockIn, now: now, rules: rules),
                           accuracy: 0.001)
        }
    }

    /// Past target the arc is simply full. Load-bearing for the collapsed-span case
    /// below, and the reason the label no longer decides this for itself.
    func testOvertimeFillsCompletely() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 19, 0)).fillProgress, 1)
    }

    /// Time off at or above the target collapses the day to a zero-length span, so
    /// `dayProgress` returns 0 while the state is `.overtime` from the first tick.
    /// Driving the arc off that number drew an empty ring in overtime orange.
    func testCollapsedDayStillFillsRatherThanReadingEmpty() {
        let clockIn = d(2026, 7, 9, 9, 0)
        let key = Calendar(identifier: .gregorian).startOfDay(for: clockIn)
        let today = WorkRecord(clockIn: clockIn, clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  weeklyOvertime: 0,
                                                  timeOff: [key: 8 * 3600],
                                                  now: d(2026, 7, 9, 9, 1), rules: rules,
                                                  calendar: seoul)
        XCTAssertEqual(display.state, .overtime(today: 60, clockedIn: true))
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: clockIn, now: d(2026, 7, 9, 9, 1),
                                                  rules: rules, timeOff: 8 * 3600), 0)
        XCTAssertEqual(display.fillProgress, 1)
    }

    /// A settled day keeps the progress it reached, measured at clock-out: 09:00–17:00
    /// against an 18:00 leave time is eight ninths of the span, and it must still read
    /// eight ninths at 22:30 rather than having crept to full over the evening.
    func testSettledDayHoldsItsProgressFromClockOut() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 22, 30),
                        clockOut: d(2026, 7, 9, 17, 0))
        XCTAssertEqual(s.state, .overtime(today: -3600, clockedIn: false))
        XCTAssertEqual(s.fillProgress, 8.0 / 9, accuracy: 0.001)
    }

    // Urgency: leave 18:00
    func testUrgencySteps() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 29)).urgency, .normal)   // 31 min
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 30)).urgency, .warning)  // 30 min
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 50)).urgency, .critical) // 10 min
    }

    /// Past 22:00 while still clocked in: critical, and today's figure keeps
    /// accruing rather than freezing at the cutoff.
    func testPastCutoffWhileClockedInIsCritical() {
        let rules = WorkRules()
        let today = WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  weeklyOvertime: 4.5 * 3600,
                                                  now: d(2026, 7, 29, 22, 30),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.urgency, .critical)
        XCTAssertEqual(display.state, .overtime(today: 4.5 * 3600, clockedIn: true))
    }

    /// Clocked out at 19:00 and left running: at 22:30 the cutoff has passed but
    /// nobody is working, so the pill must stay plain. Without the `clockedIn`
    /// guard on the cutoff branch the menu bar would turn red every night.
    func testPastCutoffWhileClockedOutIsNormal() {
        let rules = WorkRules()
        // 09:00–19:00 = 10h elapsed − 1h break = 9h net = +1h overtime, well under the cap.
        let today = WorkRecord(clockIn: d(2026, 7, 29, 9, 0),
                               clockOut: d(2026, 7, 29, 19, 0), flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  weeklyOvertime: 3600,
                                                  now: d(2026, 7, 29, 22, 30),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.urgency, .normal)
        XCTAssertEqual(display.state, .overtime(today: 1 * 3600, clockedIn: false))
    }

    /// The weekly cap is critical regardless of clock state — 12h worked is 12h
    /// worked whether or not you are currently on the clock.
    func testWeeklyCapIsCriticalEvenWhenClockedOut() {
        let rules = WorkRules()
        // One completed 12h-elapsed day, clocked out. The 12h weekly total is stated
        // rather than derived — it is four such days' worth (11h net = +3h each), and
        // that arithmetic is pinned by WorkCalculatorTests; the subject here is what
        // computeDisplay does when handed a total sitting on the cap.
        let today = WorkRecord(clockIn: d(2026, 7, 30, 8, 0),
                               clockOut: d(2026, 7, 30, 20, 0), flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  weeklyOvertime: 12 * 3600,
                                                  now: d(2026, 7, 30, 20, 30),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.urgency, .critical)
    }

    func testNoSessionAndNotClockedInAreNormalWithTimerIcon() {
        let none = DisplayState.computeDisplay(hasSession: false, today: nil,
                                               weeklyOvertime: 0,
                                               now: d(2026, 7, 9, 9, 0), rules: rules, calendar: seoul)
        XCTAssertEqual(none, MenuDisplay(state: .noSession, urgency: .normal))
        XCTAssertEqual(DisplayState.counting(timeLeft: 60).iconName, "timer")
        XCTAssertEqual(DisplayState.overtime(today: 0, clockedIn: true).iconName, "timer")
        XCTAssertEqual(DisplayState.noSession.iconName, "timer")
        XCTAssertEqual(DisplayState.notClockedIn.iconName, "timer")
    }

    /// Saturday and Sunday short-circuit the whole weekday machine, a live record
    /// included.
    func testWeekendBeatsAnyRecord() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let sat = WorkRecord(clockIn: d(2026, 8, 1, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: sat,
                                                  weeklyOvertime: 0,
                                                  now: d(2026, 8, 1, 14, 0), rules: rules,
                                                  calendar: cal)
        XCTAssertEqual(display.state, .weekend)
        XCTAssertEqual(display.urgency, .normal)
    }

    /// Signed out outranks it: "sign in" is actionable where 주말! is not.
    func testSignedOutBeatsWeekend() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let display = DisplayState.computeDisplay(hasSession: false, today: nil,
                                                  weeklyOvertime: 0,
                                                  now: d(2026, 8, 1, 14, 0), rules: rules,
                                                  calendar: cal)
        XCTAssertEqual(display.state, .noSession)
    }

    /// The Monday after is an ordinary day, so the guard is the weekday and not the
    /// presence of a record.
    func testWeekdayIsUnaffected() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let mon = WorkRecord(clockIn: d(2026, 8, 3, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: mon,
                                                  weeklyOvertime: 0,
                                                  now: d(2026, 8, 3, 14, 0), rules: rules,
                                                  calendar: cal)
        XCTAssertNotEqual(display.state, .weekend)
    }
}
