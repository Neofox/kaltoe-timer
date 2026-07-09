import XCTest
@testable import FlexTimer

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
        SettingsStore.defaults.set(4.0, forKey: "weeklyOvertimeHours")
        XCTAssertEqual(SettingsStore.rules,
                       WorkRules(dailyWork: 7 * 3600, breakTime: 30 * 60, weeklyOvertime: 4 * 3600))
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
}
