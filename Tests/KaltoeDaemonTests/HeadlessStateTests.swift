import XCTest
@testable import KaltoeCore
@testable import KaltoeDaemon

/// Date in Asia/Seoul, gregorian. Duplicated per this repo's convention:
/// separate test targets don't share top-level helpers.
private func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
}

/// Serves the given outcomes in order, repeating the last one thereafter.
/// A reference box rather than a captured `var` so the escaping closure has no
/// mutable capture.
private final class Script {
    private let outcomes: [Result<ParseResult, FlexClient.FlexError>]
    private var index = 0

    init(_ outcomes: [Result<ParseResult, FlexClient.FlexError>]) { self.outcomes = outcomes }

    func next() throws(FlexClient.FlexError) -> ParseResult {
        let outcome = outcomes[min(index, outcomes.count - 1)]
        index += 1
        switch outcome {
        case .success(let page): return page
        case .failure(let error): throw error
        }
    }
}

@MainActor
final class HeadlessStateTests: XCTestCase {
    override func setUp() {
        // status(now:) reads SettingsStore.rules, and todayRecord falls back to
        // SettingsStore.manualStart — isolate both from the developer's domain.
        SettingsStore.defaults = UserDefaults(suiteName: "daemon-tests-\(UUID().uuidString)")!
        // HeadlessState.init seeds hasSession from CookieVault.load(), so without
        // this every construction would read the developer's real session — the
        // login keychain on macOS, ~/.config/kaltoe-timer/session.json on Linux.
        // Mirrors useScratchVault() in Tests/KaltoeCoreTests/TestSupport.swift,
        // which this target cannot call across the target boundary.
        #if os(macOS)
        CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
        #else
        CookieVault.sessionFileOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaltoe-vault-test-\(UUID().uuidString)/session.json")
        #endif
    }

    /// One open record clocking in 09:00 Wed 2026-07-29. Paired with a `now` later
    /// the same day, so `todayRecord` matches on calendar day and
    /// `weekIncludingManual` keeps it (Monday of that week is 2026-07-27).
    private var page: ParseResult {
        ParseResult(records: [WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: nil,
                                         flexWorkedNet: nil)],
                    dayOffDates: [], timeOff: [:])
    }

    /// The canonical week, for the fields the tray's new rows read. Thursday is a
    /// day off; Friday 2026-07-31 is open and is the last Friday of July.
    ///
    /// Monday clocks out at 18:35:**37**, not on the minute. Flex timestamps come
    /// from epoch milliseconds (`FlexRecordParser`), so a seconds component is the
    /// norm, and without one Monday's `worked` and `overtime` would floor to the same
    /// values untruncated and prove nothing. Both expectations below are unchanged by
    /// the 37 s: net is 8:35:37 -> 8:35, overtime 35:37 -> 35:00.
    private var fullWeek: ParseResult {
        ParseResult(
            records: [
                WorkRecord(clockIn: d(2026, 7, 27, 9, 0),
                           clockOut: d(2026, 7, 27, 18, 35).addingTimeInterval(37),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 31, 9, 12), clockOut: nil, flexWorkedNet: nil),
            ],
            dayOffDates: [Calendar.current.startOfDay(for: d(2026, 7, 30, 0, 0))],
            timeOff: [:])
    }

    private func state(_ outcomes: [Result<ParseResult, FlexClient.FlexError>]) -> HeadlessState {
        let script = Script(outcomes)
        return HeadlessState { (_, _) throws(FlexClient.FlexError) in try script.next() }
    }

    func testSuccessfulRefreshPopulatesTheStatusLine() async {
        let state = state([.success(page)])
        await state.refresh()

        let line = state.status(now: d(2026, 7, 29, 15, 0))
        XCTAssertTrue(line.hasSession)
        XCTAssertNil(line.syncError)
        XCTAssertNotNil(line.lastSync)   // set from the real clock, so only non-nil is assertable
        XCTAssertEqual(line.started, d(2026, 7, 29, 9, 0))
        XCTAssertEqual(line.leaveAt, d(2026, 7, 29, 18, 0))  // 09:00 + 8h target + 1h break
        XCTAssertEqual(line.weekOvertime, 0)                 // 15:00 is before leave time
    }

    /// The three optional NDJSON fields are gated on `hasSession`, and the tray's
    /// menu rows read them. Refreshing successfully *first* is what makes this
    /// discriminating: week data survives, so nil can only come from the gate.
    func testSessionExpiredGatesEveryOptionalFieldDespiteLiveWeekData() async {
        let state = state([.success(page), .failure(FlexClient.FlexError.sessionExpired)])
        await state.refresh()
        await state.refresh()

        XCTAssertFalse(state.hasSession)
        XCTAssertEqual(state.weekData.records.count, 1, "week data must survive, or nil proves nothing")

        let line = state.status(now: d(2026, 7, 29, 15, 0))
        XCTAssertNil(line.started)
        XCTAssertNil(line.leaveAt)
        XCTAssertNil(line.weekOvertime)
    }

    /// `.noSession` and `.sessionExpired` share one switch arm, so testing only
    /// one would leave half the arm's membership unpinned.
    func testNoSessionGatesEveryOptionalFieldToo() async {
        let state = state([.success(page), .failure(FlexClient.FlexError.noSession)])
        await state.refresh()
        await state.refresh()

        XCTAssertFalse(state.hasSession)
        XCTAssertEqual(state.weekData.records.count, 1)

        let line = state.status(now: d(2026, 7, 29, 15, 0))
        XCTAssertNil(line.started)
        XCTAssertNil(line.leaveAt)
        XCTAssertNil(line.weekOvertime)
    }

    /// "Sync failure keeps last data" — the type's doc comment, previously unverified.
    func testNonSessionErrorKeepsLastKnownData() async {
        let state = state([.success(page), .failure(FlexClient.FlexError.transport)])
        await state.refresh()
        let firstSync = state.lastSync
        XCTAssertNotNil(firstSync, "precondition: the first refresh must have succeeded")
        await state.refresh()

        XCTAssertEqual(state.syncError, "Flex sync failed — showing last known data")
        XCTAssertEqual(state.lastSync, firstSync, "a failed sync must not move lastSync")
        XCTAssertEqual(state.weekData.records.count, 1)
        XCTAssertTrue(state.hasSession, "a transport error is not a session error")
    }

    func testStatusLineCarriesThePerDayRows() async throws {
        let state = state([.success(fullWeek)])
        await state.refresh()

        let line = state.status(now: d(2026, 7, 31, 14, 41))
        let days = try XCTUnwrap(line.days)
        XCTAssertEqual(days.count, 5)
        XCTAssertEqual(days.map(\.label), ["월", "화", "수", "목", "금"])
        XCTAssertEqual(days[0].worked, 8 * 3600 + 35 * 60)
        XCTAssertEqual(days[0].overtime, 35 * 60)
        XCTAssertNil(days[2].worked)                       // no Wednesday record
        XCTAssertTrue(days[3].isDayOff)                    // Thursday
        XCTAssertTrue(days[4].isOngoing)                   // Friday, still clocked in
        XCTAssertEqual(days[4].target, 6 * 3600)           // family day
        XCTAssertEqual(line.targetNote, "Target 6:00 · family day")
        XCTAssertEqual(line.weekOvertimeCap, 12 * 3600)
    }

    /// Seconds would make the daemon emit every second instead of every minute
    /// (main.swift emits on change), so every interval is minute-truncated.
    func testPerDayIntervalsAreTruncatedToWholeMinutes() async throws {
        let state = state([.success(fullWeek)])
        await state.refresh()

        // 09:12 to 14:41:37 is 5:29:37 elapsed, less the full hour of lunch.
        let line = state.status(now: d(2026, 7, 31, 14, 41).addingTimeInterval(37))
        let days = try XCTUnwrap(line.days)
        // Both discriminating: each drops a real 37 s rather than flooring a value
        // that was already on the minute. Monday from its clock-out, Friday from `now`.
        XCTAssertEqual(days[4].worked, 4 * 3600 + 29 * 60)
        XCTAssertEqual(days[0].worked, 8 * 3600 + 35 * 60)
        XCTAssertEqual(days[0].overtime, 35 * 60)

        // `target` is record-independent, so all five rows carry one.
        for (index, day) in days.enumerated() {
            XCTAssertEqual(day.target % 60, 0, "days[\(index)].target = \(day.target)")
        }
        // Only Monday and Friday have records. Looping over all five instead would
        // let the three empty days pass vacuously — `worked` is nil there, and
        // `overtime` is a hard 0 with no record to derive it from.
        for index in [0, 4] {
            let worked = try XCTUnwrap(days[index].worked, "days[\(index)] must have a record")
            XCTAssertEqual(worked % 60, 0, "days[\(index)].worked = \(worked)")
            XCTAssertEqual(days[index].overtime % 60, 0,
                           "days[\(index)].overtime = \(days[index].overtime)")
        }
        // Guards the index list above: if a fixture change gave these days records,
        // the loop would be silently skipping them.
        XCTAssertNil(days[1].worked)
        XCTAssertNil(days[2].worked)
        XCTAssertNil(days[3].worked)
    }

    /// Mirrors the existing gate on started/leaveAt/weekOvertime: refreshing
    /// successfully first is what makes nil discriminating.
    func testSessionExpiredGatesTheNewFieldsToo() async {
        let state = state([.success(fullWeek), .failure(FlexClient.FlexError.sessionExpired)])
        await state.refresh()
        await state.refresh()

        XCTAssertFalse(state.hasSession)
        XCTAssertEqual(state.weekData.records.count, 2, "week data must survive, or nil proves nothing")

        let line = state.status(now: d(2026, 7, 31, 14, 41))
        XCTAssertNil(line.days)
        XCTAssertNil(line.targetNote)
        XCTAssertNil(line.weekOvertimeCap)
    }
}
