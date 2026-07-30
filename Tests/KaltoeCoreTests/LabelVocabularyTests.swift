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

    // MARK: spokenLabel

    private func spoken(_ state: DisplayState, _ urgency: Urgency = .normal) -> String {
        MenuDisplay(state: state, urgency: urgency).spokenLabel
    }

    /// Every case announces something, and something different. The label is one
    /// rendered image with no per-element accessibility, so this string is the whole
    /// of what VoiceOver gets.
    func testSpokenLabelCoversEveryState() {
        XCTAssertEqual(spoken(.noSession), "Signed out")
        XCTAssertEqual(spoken(.notClockedIn), "Not clocked in")
        XCTAssertEqual(spoken(.toLunch(timeLeft: 80 * 60)), "1:20 until lunch")
        XCTAssertEqual(spoken(.onBreak(timeLeft: 45 * 60)), "0:45 of break left")
        XCTAssertEqual(spoken(.counting(timeLeft: 154 * 60)), "2:34 until leave time")
        XCTAssertEqual(spoken(.overtime(today: 3600, clockedIn: true), .warning),
                       "Overtime +1:00")
    }

    /// The three countdowns render the same bare `Formatting.hm`, and the glyph that
    /// separates them on screen is exactly what speech cannot see. With one figure
    /// shared between them, all three must still come out distinct.
    func testTheThreeCountdownsDoNotCollideInSpeech() {
        let left: TimeInterval = 45 * 60
        let said = [DisplayState.toLunch(timeLeft: left), .onBreak(timeLeft: left),
                    .counting(timeLeft: left)].map { spoken($0) }
        XCTAssertEqual(Set(said).count, 3, "announced \(said)")
    }

    func testSpokenOvertimeSeparatesAtLimitFromOrdinaryOvertime() {
        XCTAssertEqual(spoken(.overtime(today: 3600, clockedIn: true), .warning),
                       "Overtime +1:00")
        XCTAssertEqual(spoken(.overtime(today: 3600, clockedIn: true), .critical),
                       "Overtime +1:00, at the limit")
    }

    /// Settled outranks urgency, exactly as `LabelPhase` has it: `hasReachedWeeklyCap`
    /// yields `.critical` off the clock too, so a finished day must not announce as
    /// at-limit. The signed figure survives, negative included.
    func testSpokenSettledDayCarriesItsFigureAndIgnoresUrgency() {
        XCTAssertEqual(spoken(.overtime(today: 3600, clockedIn: false), .critical),
                       "Clocked out, +1:00 against today's target")
        XCTAssertEqual(spoken(.overtime(today: -20 * 60, clockedIn: false)),
                       "Clocked out, -0:20 against today's target")
    }

    /// 자유! is punctuation, which reads as nothing aloud. At-limit outranks it: the
    /// two coincide when the weekly cap is reached in that same minute, and the cap
    /// is the more important thing to say.
    func testSpokenJayuMinuteSaysWords() {
        XCTAssertEqual(spoken(.overtime(today: 0, clockedIn: true), .warning), "Free to go")
        XCTAssertEqual(spoken(.overtime(today: 59, clockedIn: true), .warning), "Free to go")
        XCTAssertEqual(spoken(.overtime(today: 60, clockedIn: true), .warning), "Overtime +0:01")
        XCTAssertEqual(spoken(.overtime(today: 0, clockedIn: true), .critical),
                       "Overtime +0:00, at the limit")
    }
}
