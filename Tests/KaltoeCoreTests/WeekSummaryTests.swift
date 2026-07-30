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
    /// land on one day, and the break vanishes too, so Leave at moves four hours.
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
}
