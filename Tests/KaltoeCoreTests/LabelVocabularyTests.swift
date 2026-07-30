import XCTest
@testable import KaltoeCore

final class LabelVocabularyTests: XCTestCase {
    func testLabelGlyphPerState() {
        XCTAssertEqual(DisplayState.noSession.labelGlyph, "zzz")
        XCTAssertEqual(DisplayState.notClockedIn.labelGlyph, "timer")
        XCTAssertEqual(DisplayState.toLunch(timeLeft: 80 * 60).labelGlyph, "fork.knife")
        XCTAssertEqual(DisplayState.onBreak(timeLeft: 45 * 60).labelGlyph, "cup.and.saucer")
    }

    /// The countdown turns into a walking figure inside the last half hour. Keyed
    /// off `timeLeft` directly, not off `Urgency`, which no longer drives appearance.
    func testCountingGlyphSwitchesToAFigureInTheLastHalfHour() {
        XCTAssertEqual(DisplayState.counting(timeLeft: 31 * 60).labelGlyph, "timer")
        XCTAssertEqual(DisplayState.counting(timeLeft: 30 * 60).labelGlyph, "figure.walk")
        XCTAssertEqual(DisplayState.counting(timeLeft: 60).labelGlyph, "figure.walk")
    }

    func testOvertimeGlyphDistinguishesTheCelebrationTheClockAndASettledDay() {
        XCTAssertEqual(DisplayState.overtime(today: 0, clockedIn: true).labelGlyph,
                       "figure.walk.departure")
        XCTAssertEqual(DisplayState.overtime(today: 59, clockedIn: true).labelGlyph,
                       "figure.walk.departure")
        XCTAssertEqual(DisplayState.overtime(today: 60, clockedIn: true).labelGlyph, "flame")
        XCTAssertEqual(DisplayState.overtime(today: 3600, clockedIn: true).labelGlyph, "flame")
    }

    /// `checkmark` means settled, not target met — clocking out short still lands
    /// in `.overtime`, with a negative figure and a ring that visibly did not fill.
    func testClockedOutAlwaysReadsAsSettled() {
        XCTAssertEqual(DisplayState.overtime(today: 3600, clockedIn: false).labelGlyph, "checkmark")
        XCTAssertEqual(DisplayState.overtime(today: 0, clockedIn: false).labelGlyph, "checkmark")
        XCTAssertEqual(DisplayState.overtime(today: -20 * 60, clockedIn: false).labelGlyph,
                       "checkmark")
    }

    /// The BREAK and OT words are gone — the glyph carries the phase. They stay on
    /// `menuBarText` for the Linux tray, which has no glyph.
    func testLabelTextDropsTheWordPrefixes() {
        XCTAssertEqual(DisplayState.onBreak(timeLeft: 45 * 60).labelText, "0:45")
        XCTAssertEqual(DisplayState.overtime(today: 3600, clockedIn: true).labelText, "+1:00")
        XCTAssertEqual(DisplayState.overtime(today: -20 * 60, clockedIn: false).labelText, "-0:20")
    }

    func testLabelTextForTheQuietStates() {
        XCTAssertEqual(DisplayState.noSession.labelText, "")
        XCTAssertEqual(DisplayState.notClockedIn.labelText, "--:--")
        XCTAssertEqual(DisplayState.toLunch(timeLeft: 80 * 60).labelText, "1:20")
        XCTAssertEqual(DisplayState.counting(timeLeft: 154 * 60).labelText, "2:34")
    }

    /// 자유! occupies exactly the minute `signedHM` would render as "+0:00", so it
    /// displaces no reading at all. It requires being on the clock.
    func testJayuOccupiesTheFirstMinuteOfOvertimeOnly() {
        XCTAssertEqual(DisplayState.overtime(today: 0, clockedIn: true).labelText, "자유!")
        XCTAssertEqual(DisplayState.overtime(today: 59, clockedIn: true).labelText, "자유!")
        XCTAssertEqual(DisplayState.overtime(today: 60, clockedIn: true).labelText, "+0:01")
        XCTAssertEqual(DisplayState.overtime(today: 30, clockedIn: false).labelText, "+0:00")
    }
}
