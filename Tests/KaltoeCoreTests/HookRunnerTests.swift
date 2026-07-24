import XCTest
@testable import KaltoeCore

final class HookRunnerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var fired: [(script: URL, env: [String: String])] = []

    override func setUp() {
        defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        fired = []
    }

    private func makeRunner() -> HookRunner {
        HookRunner(defaults: defaults) { [self] url, env in fired.append((url, env)) }
    }

    private let openRecord = WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)
    private let closedRecord = WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: d(2026, 7, 9, 19, 0), flexWorkedNet: nil)
    private let morning = d(2026, 7, 9, 9, 5)
    private let evening = d(2026, 7, 9, 19, 5)

    func testNoRecordNoFire() {
        makeRunner().evaluate(today: nil, now: morning)
        XCTAssertTrue(fired.isEmpty)
    }

    func testClockInFiresOnceWithEnv() {
        let runner = makeRunner()
        runner.evaluate(today: openRecord, now: morning)
        XCTAssertEqual(fired.count, 1)
        #if os(macOS)
        XCTAssertTrue(fired[0].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-in"))
        #else
        XCTAssertTrue(fired[0].script.path.hasSuffix("kaltoe-timer/hooks/on-clock-in"))
        #endif
        XCTAssertEqual(fired[0].env["KALTOE_EVENT"], "clock-in")
        XCTAssertEqual(ISO8601DateFormatter().date(from: fired[0].env["KALTOE_CLOCK_IN"] ?? ""),
                       openRecord.clockIn)
        XCTAssertNil(fired[0].env["KALTOE_CLOCK_OUT"])

        runner.evaluate(today: openRecord, now: morning) // second tick: deduped
        XCTAssertEqual(fired.count, 1)
    }

    func testClockOutFiresOnceAfterClockOutAppears() {
        let runner = makeRunner()
        runner.evaluate(today: openRecord, now: morning)   // clock-in fires
        runner.evaluate(today: closedRecord, now: evening) // clock-out fires
        XCTAssertEqual(fired.count, 2)
        #if os(macOS)
        XCTAssertTrue(fired[1].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-out"))
        #else
        XCTAssertTrue(fired[1].script.path.hasSuffix("kaltoe-timer/hooks/on-clock-out"))
        #endif
        XCTAssertEqual(fired[1].env["KALTOE_EVENT"], "clock-out")
        XCTAssertEqual(ISO8601DateFormatter().date(from: fired[1].env["KALTOE_CLOCK_IN"] ?? ""),
                       closedRecord.clockIn)
        XCTAssertEqual(ISO8601DateFormatter().date(from: fired[1].env["KALTOE_CLOCK_OUT"] ?? ""),
                       closedRecord.clockOut)

        runner.evaluate(today: closedRecord, now: evening) // deduped
        XCTAssertEqual(fired.count, 2)
    }

    func testLateDetectionFiresBothOnce() {
        // App launched after both events already happened: fire each exactly once.
        makeRunner().evaluate(today: closedRecord, now: evening)
        XCTAssertEqual(fired.map { $0.env["KALTOE_EVENT"] }, ["clock-in", "clock-out"])
    }

    func testDedupePersistsAcrossInstances() {
        makeRunner().evaluate(today: openRecord, now: morning)
        makeRunner().evaluate(today: openRecord, now: morning) // fresh runner, same defaults
        XCTAssertEqual(fired.count, 1)
    }

    func testReClockInDoesNotRefireEitherHook() {
        let runner = makeRunner()
        runner.evaluate(today: closedRecord, now: evening)  // fires both
        runner.evaluate(today: openRecord, now: evening)    // clockOut reverted
        runner.evaluate(today: closedRecord, now: evening)  // clocked out again
        XCTAssertEqual(fired.count, 2)
    }

    #if !os(macOS)
    func testHooksDirectoryHonorsConfigDirOverride() {
        setenv("KALTOE_CONFIG_DIR", "/tmp/kaltoe-test-config", 1)
        defer { unsetenv("KALTOE_CONFIG_DIR") }
        XCTAssertEqual(HookRunner.hooksDirectory.path, "/tmp/kaltoe-test-config/hooks")
    }
    #endif

    func testStaleKeysRemovedWhenNewDayFires() {
        defaults.set(true, forKey: "hookFired-clockIn-2026-07-08")
        defaults.set(true, forKey: "hookFired-clockOut-2026-07-08")
        makeRunner().evaluate(today: openRecord, now: morning)
        XCTAssertNil(defaults.object(forKey: "hookFired-clockIn-2026-07-08"))
        XCTAssertNil(defaults.object(forKey: "hookFired-clockOut-2026-07-08"))
        XCTAssertNotNil(defaults.object(forKey: "hookFired-clockIn-2026-07-09"))
    }
}
