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
        XCTAssertEqual(DisplayState.noSession.menuBarText, "⏳ —")
    }

    func testNotClockedIn() {
        XCTAssertEqual(DisplayState.compute(hasSession: true, today: nil, week: [],
                                            now: d(2026, 7, 6, 8, 0), rules: rules), .notClockedIn)
        XCTAssertEqual(DisplayState.notClockedIn.menuBarText, "⏳ --:--")
    }

    func testCountingDuringDay() {
        let today = WorkRecord(clockIn: d(2026, 7, 6, 8, 59), clockOut: nil, flexWorkedNet: nil)
        let s = DisplayState.compute(hasSession: true, today: today, week: [today],
                                     now: d(2026, 7, 6, 15, 25), rules: rules)
        XCTAssertEqual(s, .counting(timeLeft: 2 * 3600 + 34 * 60))
        XCTAssertEqual(s.menuBarText, "⏳ 2:34")
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
