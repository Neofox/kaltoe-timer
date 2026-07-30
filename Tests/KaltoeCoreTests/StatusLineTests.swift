import XCTest
@testable import KaltoeCore

final class StatusLineTests: XCTestCase {
    func testMapsDisplayFields() {
        let line = StatusLine(display: MenuDisplay(state: .overtime(today: -59 * 60),
                                                   urgency: .critical),
                              hasSession: true, lastSync: nil, syncError: nil)
        XCTAssertEqual(line.text, "OT -0:59")
        XCTAssertEqual(line.icon, "timer")
        XCTAssertEqual(line.urgency, "critical")
    }

    func testEncodesStableSortedJSONOmittingNils() throws {
        let line = StatusLine(display: MenuDisplay(state: .noSession, urgency: .normal),
                              hasSession: false, lastSync: nil, syncError: nil)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8)
        XCTAssertEqual(json, #"{"hasSession":false,"icon":"timer","text":"—","urgency":"normal"}"#)
    }

    func testEncodesLastSyncAsISO8601() throws {
        let line = StatusLine(display: MenuDisplay(state: .notClockedIn, urgency: .normal),
                              hasSession: true,
                              lastSync: Date(timeIntervalSince1970: 0), syncError: nil)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""lastSync":"1970-01-01T00:00:00Z""#), json)
    }

    func testDetailFieldsOmittedByDefault() throws {
        let line = StatusLine(display: MenuDisplay(state: .noSession, urgency: .normal),
                              hasSession: false, lastSync: nil, syncError: nil)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("started"), json)
        XCTAssertFalse(json.contains("leaveAt"), json)
        XCTAssertFalse(json.contains("weekOvertime"), json)
    }

    func testDetailFieldsEncodeWhenSet() throws {
        let line = StatusLine(display: MenuDisplay(state: .counting(timeLeft: 3600), urgency: .normal),
                              hasSession: true, lastSync: nil, syncError: nil,
                              started: Date(timeIntervalSince1970: 0),
                              leaveAt: Date(timeIntervalSince1970: 9 * 3600),
                              weekOvertime: 240)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""started":"1970-01-01T00:00:00Z""#), json)
        XCTAssertTrue(json.contains(#""leaveAt":"1970-01-01T09:00:00Z""#), json)
        XCTAssertTrue(json.contains(#""weekOvertime":240"#), json)
    }

    func testWeekOvertimeRoundsToWholeMinutesTowardZero() {
        func line(_ ot: TimeInterval) -> StatusLine {
            StatusLine(display: MenuDisplay(state: .notClockedIn, urgency: .normal),
                       hasSession: true, lastSync: nil, syncError: nil,
                       started: nil, leaveAt: nil, weekOvertime: ot)
        }
        XCTAssertEqual(line(250).weekOvertime, 240)    // 4m10s -> 4m
        XCTAssertEqual(line(-250).weekOvertime, -240)  // -4m10s -> -4m (toward zero, matches signedHM)
        XCTAssertEqual(line(0).weekOvertime, 0)
    }

    /// `Int(Double)` **traps** on NaN, ±infinity or an out-of-range magnitude, and this
    /// is reachable from settings rather than only from bad arithmetic:
    /// `weeklyOvertimeCapHours` is a `defaults write` knob README documents, and it
    /// reaches `weekOvertimeCap` unfiltered. A typo there crash-looped the daemon
    /// (SIGTRAP, exit 133) before the clamp landed — verified by hand then, pinned here,
    /// because the next regression would be silent until someone's daemon stopped
    /// coming back. Garbage in must yield 0: a visibly wrong row beats no daemon.
    func testNonFiniteAndOutOfRangeIntervalsClampToZero() {
        XCTAssertEqual(StatusLine.secondsFlooredToMinute(.nan), 0)
        XCTAssertEqual(StatusLine.secondsFlooredToMinute(.infinity), 0)
        XCTAssertEqual(StatusLine.secondsFlooredToMinute(-.infinity), 0)
        XCTAssertEqual(StatusLine.secondsFlooredToMinute(1e300), 0)
    }
}
