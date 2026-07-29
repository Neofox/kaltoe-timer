import XCTest
@testable import KaltoeCore

final class SettingsStoreTests: XCTestCase {
    override func setUp() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
    }

    func testDefaultRules() {
        XCTAssertEqual(SettingsStore.rules, WorkRules())
    }

    func testOverriddenRules() {
        SettingsStore.defaults.set(7.0, forKey: "dailyWorkHours")
        SettingsStore.defaults.set(30.0, forKey: "breakMinutes")
        var expected = WorkRules()
        expected.dailyWork = 7 * 3600
        expected.breakTime = 30 * 60
        XCTAssertEqual(SettingsStore.rules, expected)
    }

    func testManualStartRoundTripAndClear() {
        let day = d(2026, 7, 9, 0, 0)
        XCTAssertNil(SettingsStore.manualStart(on: day))
        let start = d(2026, 7, 9, 8, 59)
        SettingsStore.setManualStart(start, on: day)
        XCTAssertEqual(SettingsStore.manualStart(on: day), start)
        SettingsStore.setManualStart(nil, on: day)
        XCTAssertNil(SettingsStore.manualStart(on: day))
    }

    func testDefaultLunchRules() {
        let r = SettingsStore.rules
        XCTAssertEqual(r.lunchStart, 690 * 60)
        XCTAssertEqual(r.lunchEnd, 750 * 60)
        XCTAssertEqual(r.lunchEarlyLeave, 10 * 60)
    }

    func testOverriddenLunchRules() {
        SettingsStore.defaults.set(720.0, forKey: "lunchStartMinutes")
        SettingsStore.defaults.set(780.0, forKey: "lunchEndMinutes")
        SettingsStore.defaults.set(0.0, forKey: "lunchEarlyLeaveMinutes")
        let r = SettingsStore.rules
        XCTAssertEqual(r.lunchStart, 720 * 60)
        XCTAssertEqual(r.lunchEnd, 780 * 60)
        XCTAssertEqual(r.lunchEarlyLeave, 0)
    }

    func testDefaultHolidayAndFamilyDayRules() {
        let r = SettingsStore.rules
        XCTAssertEqual(r.familyDayEarlyLeave, 2 * 3600)
    }

    func testOverriddenHolidayAndFamilyDayRules() {
        SettingsStore.defaults.set(0.0, forKey: "familyDayEarlyLeaveHours")
        let r = SettingsStore.rules
        XCTAssertEqual(r.familyDayEarlyLeave, 0)
    }

    func testHighContrastDefaultsToOff() {
        XCTAssertFalse(SettingsStore.highContrastOnInactiveDisplays)
    }

    func testHighContrastRoundTrips() {
        SettingsStore.highContrastOnInactiveDisplays = true
        XCTAssertTrue(SettingsStore.highContrastOnInactiveDisplays)
        XCTAssertTrue(SettingsStore.defaults.bool(forKey: "highContrastOnInactiveDisplays"))
        SettingsStore.highContrastOnInactiveDisplays = false
        XCTAssertFalse(SettingsStore.highContrastOnInactiveDisplays)
    }

    func testDefaultOvertimeLimits() {
        let r = SettingsStore.rules
        XCTAssertEqual(r.weeklyOvertimeCap, 12 * 3600)
        XCTAssertEqual(r.overtimeCutoff, 22 * 3600)
    }

    func testOverriddenOvertimeLimits() {
        SettingsStore.defaults.set(10.0, forKey: "weeklyOvertimeCapHours")
        SettingsStore.defaults.set(1260.0, forKey: "overtimeCutoffMinutes")  // 21:00
        let r = SettingsStore.rules
        XCTAssertEqual(r.weeklyOvertimeCap, 10 * 3600)
        XCTAssertEqual(r.overtimeCutoff, 1260 * 60)
    }
}
