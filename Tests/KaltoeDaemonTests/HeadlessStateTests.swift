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
    private let outcomes: [Result<ParseResult, Error>]
    private var index = 0

    init(_ outcomes: [Result<ParseResult, Error>]) { self.outcomes = outcomes }

    func next() throws -> ParseResult {
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

    private func state(_ outcomes: [Result<ParseResult, Error>]) -> HeadlessState {
        let script = Script(outcomes)
        return HeadlessState { _, _ in try script.next() }
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

    /// The `where` clause matches two cases; testing one would leave half unpinned.
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
        let state = state([.success(page), .failure(URLError(.timedOut))])
        await state.refresh()
        let firstSync = state.lastSync
        XCTAssertNotNil(firstSync, "precondition: the first refresh must have succeeded")
        await state.refresh()

        XCTAssertEqual(state.syncError, "Flex sync failed — showing last known data")
        XCTAssertEqual(state.lastSync, firstSync, "a failed sync must not move lastSync")
        XCTAssertEqual(state.weekData.records.count, 1)
        XCTAssertTrue(state.hasSession, "a transport error is not a session error")
    }
}
