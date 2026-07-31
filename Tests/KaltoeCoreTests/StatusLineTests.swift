import XCTest
@testable import KaltoeCore

final class StatusLineTests: XCTestCase {
    func testMapsDisplayFields() {
        // `clockedIn: false`, because a day that finished 59 minutes short is by
        // definition a day you clocked out of: `computeDisplay` clamps clocked-in
        // overtime at `max(0, …)`, so the clocked-in pairing is unreachable — and it
        // would make `labelText` read 자유! for a day that never reached target.
        // `.critical` is still right off the clock; the weekly cap yields it either way.
        let line = StatusLine(display: MenuDisplay(state: .overtime(today: -59 * 60, clockedIn: false),
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

    /// Pins every state's wire output. The eight `.overtime`-and-earlier rows are
    /// **frozen** — `kaltoe-tray.py` maps exactly `timer`/`fork.knife`/`cup.and.saucer`
    /// in `ICON_BASE` and falls back to a generic timer for anything else, its
    /// `LABEL_GUIDE` is sized from the `OT ` prefix, and `render_text_icon` stacks the
    /// label at the first space, which on KDE is the only phase signal there is since
    /// that tray renders the text alone with no glyph. The Mac's expressive glyphs and
    /// prefix-free text live on `labelGlyph`/`labelText` instead. If one of those rows
    /// fails, the Linux tray has regressed.
    ///
    /// `.weekend` is **additive**, not frozen: it is a new state rather than a change to
    /// an existing one, so `beach.umbrella` reaching `ICON_BASE` degrades to the generic
    /// timer icon via `.get`, and `주말!` has no space to stack at and is narrower than
    /// the guide.
    func testWireTextAndIconForEveryState() {
        let cases: [(DisplayState, String, String)] = [
            (.noSession, "—", "timer"),
            (.notClockedIn, "--:--", "timer"),
            (.toLunch(timeLeft: 80 * 60), "1:20", "fork.knife"),
            (.onBreak(timeLeft: 45 * 60), "BREAK 0:45", "cup.and.saucer"),
            (.counting(timeLeft: 154 * 60), "2:34", "timer"),
            (.overtime(today: 3600, clockedIn: true), "OT +1:00", "timer"),
            (.overtime(today: 3600, clockedIn: false), "OT +1:00", "timer"),
            (.overtime(today: -20 * 60, clockedIn: false), "OT -0:20", "timer"),
            (.weekend, "주말!", "beach.umbrella"),
        ]
        for (state, text, icon) in cases {
            XCTAssertEqual(state.menuBarText, text, "menuBarText for \(state)")
            XCTAssertEqual(state.iconName, icon, "iconName for \(state)")
        }
    }
}
