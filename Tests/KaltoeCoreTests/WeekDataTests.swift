import XCTest
@testable import KaltoeCore

final class WeekDataTests: XCTestCase {
    override func setUp() {
        SettingsStore.defaults = UserDefaults(suiteName: "kaltoe-weekdata-\(UUID().uuidString)")!
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d,
                                                   hour: h, minute: mi))!
    }

    func testTodayRecordPrefersFlexOverManual() {
        let now = date(2026, 7, 8, 14, 0)
        let flex = WorkRecord(clockIn: date(2026, 7, 8, 9, 0), clockOut: nil, flexWorkedNet: nil)
        SettingsStore.setManualStart(date(2026, 7, 8, 10, 0), on: now)
        let data = WeekData(records: [flex], dayOffDates: [], timeOff: [:])
        XCTAssertEqual(data.todayRecord(now: now), flex)
    }

    func testTodayRecordFallsBackToManual() {
        let now = date(2026, 7, 8, 14, 0)
        let manual = date(2026, 7, 8, 10, 0)
        SettingsStore.setManualStart(manual, on: now)
        let data = WeekData(records: [], dayOffDates: [], timeOff: [:])
        XCTAssertEqual(data.todayRecord(now: now),
                       WorkRecord(clockIn: manual, clockOut: nil, flexWorkedNet: nil))
    }

    func testWeekIncludingManualAppendsSyntheticToday() {
        let now = date(2026, 7, 8, 14, 0)
        let monday = WorkRecord(clockIn: date(2026, 7, 6, 9, 0),
                                clockOut: date(2026, 7, 6, 18, 0), flexWorkedNet: 8 * 3600)
        SettingsStore.setManualStart(date(2026, 7, 8, 10, 0), on: now)
        let data = WeekData(records: [monday], dayOffDates: [], timeOff: [:])
        XCTAssertEqual(data.weekIncludingManual(now: now).count, 2)
    }
}
