import Foundation
import KaltoeCore

/// AppState's fetch/compute loop without the AppKit shell. Same refresh
/// semantics: sync failure keeps last data, dead session flips hasSession.
@MainActor
final class HeadlessState {
    private let client = FlexClient()
    private(set) var weekData = WeekData()
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    private(set) var hasSession = CookieVault.load()?.isEmpty == false

    func refresh() async {
        do {
            let now = Date()
            let weekStart = WorkCalculator.weekStart(of: now)
            let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? now
            let result = try await client.fetchWeek(from: weekStart, to: max(now, weekEnd))
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
        let display = DisplayState.computeDisplay(hasSession: hasSession,
                                                  today: today,
                                                  week: week,
                                                  dayOffs: weekData.dayOffDates,
                                                  timeOff: weekData.timeOff,
                                                  now: now, rules: rules)
        var leaveAt: Date?
        if hasSession, let today {
            let off = WorkCalculator.timeOff(on: today.clockIn, in: weekData.timeOff)
            leaveAt = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules, timeOff: off)
        }
        let weekOvertime: TimeInterval? = hasSession
            ? WorkCalculator.weeklyOvertime(records: week, dayOffs: weekData.dayOffDates,
                                            timeOff: weekData.timeOff, now: now, rules: rules)
            : nil
        return StatusLine(display: display, hasSession: hasSession,
                          lastSync: lastSync, syncError: syncError,
                          started: hasSession ? today?.clockIn : nil,
                          leaveAt: leaveAt, weekOvertime: weekOvertime)
    }
}
