import Foundation
import KaltoeCore

/// AppState's fetch/compute loop without the AppKit shell. Same refresh
/// semantics: sync failure keeps last data, dead session flips hasSession.
@MainActor
final class HeadlessState {
    /// Injected so tests can drive refresh()'s outcomes without a network.
    /// FlexClient builds its own ephemeral URLSession and exposes no seam of its
    /// own, so this initialiser is the only place a fake can go in.
    private let fetchWeek: (Date, Date) async throws -> ParseResult

    init(fetchWeek: ((Date, Date) async throws -> ParseResult)? = nil) {
        if let fetchWeek {
            self.fetchWeek = fetchWeek
        } else {
            let client = FlexClient()
            self.fetchWeek = { try await client.fetchWeek(from: $0, to: $1) }
        }
    }
    private(set) var weekData = WeekData()
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    private(set) var hasSession = CookieVault.load()?.isEmpty == false

    func refresh() async {
        do {
            let now = Date()
            let weekStart = WorkCalculator.weekStart(of: now)
            let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? now
            let result = try await fetchWeek(weekStart, max(now, weekEnd))
            weekData = WeekData(records: result.records, dayOffDates: result.dayOffDates,
                                timeOff: result.timeOff)
            lastSync = now
            syncError = nil
            hasSession = true
        } catch let e as FlexClient.FlexError where e == .noSession || e == .sessionExpired {
            hasSession = false
        } catch {
            syncError = "Flex sync failed — showing last known data"
        }
    }

    func status(now: Date) -> StatusLine {
        let today = weekData.todayRecord(now: now)
        let week = weekData.weekIncludingManual(now: now)
        let rules = SettingsStore.rules
        // One computation feeds both the display's cap check and the status
        // line's own field; this used to be derived twice.
        let weekly = WorkCalculator.weeklyOvertime(records: week,
                                                   timeOff: weekData.timeOff,
                                                   now: now, rules: rules)
        let display = DisplayState.computeDisplay(hasSession: hasSession,
                                                  today: today,
                                                  weeklyOvertime: weekly,
                                                  timeOff: weekData.timeOff,
                                                  now: now, rules: rules)
        var leaveAt: Date?
        if hasSession, let today {
            let off = WorkCalculator.timeOff(on: today.clockIn, in: weekData.timeOff)
            leaveAt = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules, timeOff: off)
        }
        return StatusLine(display: display, hasSession: hasSession,
                          lastSync: lastSync, syncError: syncError,
                          started: hasSession ? today?.clockIn : nil,
                          leaveAt: leaveAt, weekOvertime: hasSession ? weekly : nil)
    }
}
