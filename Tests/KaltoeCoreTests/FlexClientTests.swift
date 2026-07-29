import XCTest
@testable import KaltoeCore

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

    // MARK: - Time-off blocks (docs/superpowers/specs/2026-07-10-timeoff-blocks-design.md)

    private var emptyClock: Data { Data("{\"records\":[]}".utf8) }

    func testFullDayTimeOffBlockDecodesAndJoinsDayOffDates() throws {
        // FORBIDDEN_TIME_OFF has no startTimestamp — decoding must not throw (regression).
        let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                                clock: emptyClock)
        XCTAssertTrue(result.dayOffDates.contains(Calendar.current.startOfDay(for: d(2025, 11, 24, 0, 0))),
                      "allDay time-off block must count as a full weekday off")
    }

    func testHalfDayProducesTimeOffSeconds() throws {
        let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                                clock: emptyClock)
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        XCTAssertEqual(result.timeOff[friday], 240 * 60)
        XCTAssertFalse(result.dayOffDates.contains(friday), "half-day is not a full day off")
    }

    func testHalfDayStillProducesWorkRecord() throws {
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                                 clock: emptyClock).records
        let rec = records.first { Calendar.current.isDate($0.clockIn, inSameDayAs: d(2026, 1, 2, 12, 0)) }
        XCTAssertEqual(rec?.clockIn, d(2026, 1, 2, 8, 55))
        XCTAssertEqual(rec?.clockOut, d(2026, 1, 2, 12, 30))
    }

    func testHolidayAndWeekendMarkersOnTimeOffFixture() throws {
        let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                                clock: emptyClock)
        // Weekday CUSTOM_HOLIDAY (Thu 2026-01-01) is a day off.
        XCTAssertTrue(result.dayOffDates.contains(Calendar.current.startOfDay(for: d(2026, 1, 1, 0, 0))))
        // Sunday with WEEKLY_HOLIDAY + CUSTOM_HOLIDAY is NOT (weekday filter).
        XCTAssertFalse(result.dayOffDates.contains(Calendar.current.startOfDay(for: d(2026, 3, 1, 0, 0))))
    }

    func testUnapprovedTimeOffIgnored() throws {
        let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                                clock: emptyClock)
        let monday = Calendar.current.startOfDay(for: d(2026, 3, 2, 0, 0))
        XCTAssertNil(result.timeOff[monday], "PENDING approval must not count")
        XCTAssertFalse(result.dayOffDates.contains(monday))
    }

    func testExistingFixtureHasNoTimeOffEntries() throws {
        let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                                clock: try fixture("sample-clock"))
        XCTAssertTrue(result.timeOff.isEmpty)
    }

    func testFlexWorkedNetComputedFromWorkMinusRest() throws {
        // Existing fixture 07-01: WORK 09:00–19:00 (10h), REST 1h → net 9h.
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                                 clock: try fixture("sample-clock")).records
        XCTAssertEqual(records[0].flexWorkedNet, 9 * 3600)
    }

    func testFlexWorkedNetOnHalfDay() throws {
        // 2026-01-02: WORK 08:55–12:30 (3h35m), REST 11:30–12:30 (1h) → net 2h35m.
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                                 clock: emptyClock).records
        let rec = records.first { Calendar.current.isDate($0.clockIn, inSameDayAs: d(2026, 1, 2, 12, 0)) }
        XCTAssertEqual(rec?.flexWorkedNet, 2 * 3600 + 35 * 60)
    }

    // MARK: - Outside-work request overlays (docs/FLEX_OUTSIDE_WORK_INTEGRATION.md)

    func testOngoingDayWithOutsideWorkRequestUsesClockStart() throws {
        // 2026-07-15: clocked in 08:18 (ongoing), with a pending 외근 request
        // 08:30–11:30 that Flex returns as a schedule WORK block (eventSource
        // NORMAL). The overlay must not masquerade as a completed day.
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-outside-work"),
                                                 clock: try fixture("sample-clock-outside-work")).records
        let rec = records.first { Calendar.current.isDate($0.clockIn, inSameDayAs: d(2026, 7, 15, 12, 0)) }
        XCTAssertEqual(rec?.clockIn, d(2026, 7, 15, 8, 18), "started-at must come from the clock record")
        XCTAssertNil(rec?.clockOut, "day is still ongoing")
        XCTAssertNil(rec?.flexWorkedNet, "no finalized net for an open day")
    }

    func testCompletedDayIgnoresOutsideWorkOverlayInNet() throws {
        // 2026-07-14: actual WORK_CLOCK 09:00–18:00 with 1h rest, plus an
        // approved 외근 overlay 10:00–12:00 duplicating part of the same work.
        // Net must be 8h, not 8h + the overlay's 2h.
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-outside-work"),
                                                 clock: try fixture("sample-clock-outside-work")).records
        let rec = records.first { Calendar.current.isDate($0.clockIn, inSameDayAs: d(2026, 7, 14, 12, 0)) }
        XCTAssertEqual(rec?.clockIn, d(2026, 7, 14, 9, 0))
        XCTAssertEqual(rec?.clockOut, d(2026, 7, 14, 18, 0))
        XCTAssertEqual(rec?.flexWorkedNet, 8 * 3600)
    }

    func testOngoingClockRecordHasNilFlexWorkedNet() throws {
        let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                                 clock: try fixture("sample-clock")).records
        XCTAssertNil(records[6].flexWorkedNet, "open day from work-clock has no net yet")
    }
}

final class FlexClientTests: XCTestCase {
    func testFetchWithoutSessionThrowsNoSession() async {
        useScratchVault()
        defer { CookieVault.clear() }
        do {
            _ = try await FlexClient().fetchWeek(from: Date(), to: Date())
            XCTFail("expected throw")
        } catch {
            // Typed throws: `error` is a FlexError, so no defensive arm is needed.
            XCTAssertEqual(error, .noSession)
        }
    }

    func testFetchWithCookiesButNoUserIdHashThrowsNoSession() async {
        useScratchVault()
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        defer { CookieVault.clear() }
        CookieVault.saveStored([StoredCookie(name: "AID", value: "x", domain: ".flex.team", path: "/", expires: nil)])
        do {
            _ = try await FlexClient().fetchWeek(from: Date(), to: Date())
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error, .noSession, "empty userIdHash must read as no session (nothing to query)")
        }
    }
}
