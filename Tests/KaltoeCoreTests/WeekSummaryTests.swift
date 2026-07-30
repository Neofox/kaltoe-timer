import XCTest
@testable import KaltoeCore

final class TargetNoteTests: XCTestCase {
    /// An ordinary Wednesday: nothing shortened the day, so there is nothing to say.
    func testOrdinaryDayHasNoNote() {
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 29, 9, 0), rules: rules, timeOff: [:]))
    }

    /// 2026-07-31 is the last Friday of July, so the family-day reduction applies.
    func testFamilyDayAlone() {
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: rules, timeOff: [:]),
                       "Target 6:00 · family day")
    }

    func testTimeOffAlone() {
        let key = Calendar.current.startOfDay(for: d(2026, 7, 29, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 29, 9, 0), rules: rules,
                                          timeOff: [key: 2 * 3600]),
                       "Target 6:00 · time off")
    }

    /// The compounding case, and the reason this feature exists: both reductions
    /// land on one day, and because a 4h target is at or below half a day the break
    /// vanishes with them, so Leave at moves five hours, not four — 18:12 to 13:12
    /// (clock-in + 8h + 1h break, versus clock-in + 4h + no break).
    func testFamilyDayAndTimeOffStack() {
        let key = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: rules,
                                          timeOff: [key: 2 * 3600]),
                       "Target 4:00 · family day, time off")
    }

    /// A Friday that is not the last one in its month is an ordinary day.
    func testNonFinalFridayIsNotAFamilyDay() {
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 24, 9, 0), rules: rules, timeOff: [:]))
    }

    /// familyDayEarlyLeave == 0 disables the whole policy (WorkRules' documented
    /// convention), so the note must disappear with it.
    func testFamilyDayDisabledByRules() {
        var off = WorkRules()
        off.familyDayEarlyLeave = 0
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: off, timeOff: [:]))
    }

    /// The family-day gate at compose's line 16, which no other test reaches:
    /// testFamilyDayDisabledByRules exits at the earlier target < dailyWork guard,
    /// so without this, deleting the gate leaves the whole suite green while a
    /// disabled policy gets named in the caption.
    func testFamilyDayDisabledStillNamesTimeOffAlone() {
        var off = WorkRules()
        off.familyDayEarlyLeave = 0
        let key = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: off,
                                          timeOff: [key: 2 * 3600]),
                       "Target 6:00 · time off")
    }
}
