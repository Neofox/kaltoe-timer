import Foundation

/// Snapshot of a fetched week plus the manual-start fallback, shared by the
/// macOS AppState and the Linux headless daemon.
public struct WeekData {
    public var records: [WorkRecord]
    public var dayOffDates: Set<Date>
    public var timeOff: [Date: TimeInterval]

    public init(records: [WorkRecord] = [], dayOffDates: Set<Date> = [],
                timeOff: [Date: TimeInterval] = [:]) {
        self.records = records
        self.dayOffDates = dayOffDates
        self.timeOff = timeOff
    }

    /// Flex record for the day if present, else a synthetic record from manual entry.
    public func todayRecord(now: Date) -> WorkRecord? {
        if let flex = records.first(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }) {
            return flex
        }
        if let manual = SettingsStore.manualStart(on: now) {
            return WorkRecord(clockIn: manual, clockOut: nil, flexWorkedNet: nil)
        }
        return nil
    }

    /// Week records including the synthetic manual record for today, if any.
    public func weekIncludingManual(now: Date) -> [WorkRecord] {
        let weekStart = WorkCalculator.weekStart(of: now)
        var result = records.filter { $0.clockIn >= weekStart }
        if !result.contains(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }),
           let manual = todayRecord(now: now) {
            result.append(manual)
        }
        return result
    }
}
