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
        let display = DisplayState.computeDisplay(hasSession: hasSession,
                                                  today: weekData.todayRecord(now: now),
                                                  week: weekData.weekIncludingManual(now: now),
                                                  dayOffs: weekData.dayOffDates,
                                                  timeOff: weekData.timeOff,
                                                  now: now, rules: SettingsStore.rules)
        return StatusLine(display: display, hasSession: hasSession,
                          lastSync: lastSync, syncError: syncError)
    }
}
