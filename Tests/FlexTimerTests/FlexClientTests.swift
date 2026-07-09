import XCTest
@testable import FlexTimer

final class FlexRecordParserTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    func testParsesMergedFixtures() throws {
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                                 clock: try fixture("sample-clock")).records

        XCTAssertEqual(records.count, 7)
        XCTAssertEqual(records.map(\.clockIn), records.map(\.clockIn).sorted(), "must be sorted by clockIn")

        XCTAssertEqual(records[0].clockIn, d(2026, 7, 1, 9, 0))
        XCTAssertEqual(records[0].clockOut, d(2026, 7, 1, 19, 0))

        XCTAssertEqual(records[1].clockIn, d(2026, 7, 2, 9, 10))
        XCTAssertEqual(records[1].clockOut, d(2026, 7, 2, 18, 10))

        XCTAssertEqual(records[2].clockIn, d(2026, 7, 3, 8, 55))
        XCTAssertEqual(records[2].clockOut, d(2026, 7, 3, 18, 0))

        XCTAssertEqual(records[3].clockIn, d(2026, 7, 6, 9, 0))
        XCTAssertEqual(records[3].clockOut, d(2026, 7, 6, 20, 0))

        XCTAssertEqual(records[4].clockIn, d(2026, 7, 7, 9, 5))
        XCTAssertEqual(records[4].clockOut, d(2026, 7, 7, 18, 30))

        XCTAssertEqual(records[5].clockIn, d(2026, 7, 8, 9, 0))
        XCTAssertEqual(records[5].clockOut, d(2026, 7, 8, 18, 45))

        // Last record is the ongoing day, sourced from the clock fixture (no clockOut).
        XCTAssertEqual(records[6].clockIn, d(2026, 7, 9, 9, 0))
        XCTAssertNil(records[6].clockOut)
    }

    func testWeekendDaysProduceNoRecords() throws {
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                                 clock: try fixture("sample-clock")).records
        let dates = Set(records.map { Calendar(identifier: .gregorian).component(.day, from: $0.clockIn) })
        // 07-04 (REST_DAY) and 07-05 (WEEKLY_HOLIDAY) must not appear.
        XCTAssertFalse(dates.contains(4))
        XCTAssertFalse(dates.contains(5))
    }

    func testSchedulesAloneWithEmptyClockYieldsSixRecords() throws {
        let emptyClock = Data("{\"records\":[]}".utf8)
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"), clock: emptyClock).records
        XCTAssertEqual(records.count, 6)
        // No ongoing 07-09 record is synthesized when the clock response is empty.
        XCTAssertFalse(records.contains { Calendar(identifier: .gregorian).component(.day, from: $0.clockIn) == 9 })
    }

    func testGarbageSchedulesDataThrows() {
        XCTAssertThrowsError(
            try FlexRecordParser.parse(schedules: Data("not json".utf8), clock: Data("{\"records\":[]}".utf8)))
    }

    func testGarbageClockDataThrows() throws {
        XCTAssertThrowsError(
            try FlexRecordParser.parse(schedules: try fixture("sample-schedules"), clock: Data("not json".utf8)))
    }

    func testParseReportsWeekdayDayOffs() throws {
        let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                                clock: try fixture("sample-clock"))
        let expected: Set<Date> = [
            Calendar.current.startOfDay(for: d(2026, 7, 8, 0, 0)),   // half-day: dayOff + WORK blocks
            Calendar.current.startOfDay(for: d(2026, 7, 10, 0, 0)),  // full-day vacation
        ]
        XCTAssertEqual(result.dayOffDates, expected)
        // Weekend markers (REST_DAY 07-04, WEEKLY_HOLIDAY 07-05) are NOT day-offs.
    }
}

final class FlexClientTests: XCTestCase {
    func testFetchWithoutSessionThrowsNoSession() async {
        CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
        defer { CookieVault.clear() }
        do {
            _ = try await FlexClient().fetchWeek(from: Date(), to: Date())
            XCTFail("expected throw")
        } catch let e as FlexClient.FlexError {
            XCTAssertEqual(e, .noSession)
        } catch { XCTFail("unexpected error \(error)") }
    }

    func testFetchWithCookiesButNoUserIdHashThrowsNoSession() async {
        CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        defer { CookieVault.clear() }
        CookieVault.saveStored([StoredCookie(name: "AID", value: "x", domain: ".flex.team", path: "/", expires: nil)])
        do {
            _ = try await FlexClient().fetchWeek(from: Date(), to: Date())
            XCTFail("expected throw")
        } catch let e as FlexClient.FlexError {
            XCTAssertEqual(e, .noSession, "empty userIdHash must read as no session (nothing to query)")
        } catch { XCTFail("unexpected error \(error)") }
    }
}
