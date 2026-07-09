import Foundation

enum DisplayState: Equatable {
    case noSession
    case notClockedIn
    case counting(timeLeft: TimeInterval)
    case overtime(weekly: TimeInterval)

    /// Smart single value: countdown while on the clock before leave time,
    /// weekly overtime position otherwise.
    static func compute(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                        now: Date, rules: WorkRules) -> DisplayState {
        guard hasSession else { return .noSession }
        guard let today else { return .notClockedIn }
        let left = WorkCalculator.timeLeft(clockIn: today.clockIn, now: now, rules: rules)
        if today.clockOut == nil && left > 0 { return .counting(timeLeft: left) }
        return .overtime(weekly: WorkCalculator.weeklyOvertime(records: week, now: now, rules: rules))
    }

    var menuBarText: String {
        switch self {
        case .noSession: return "⏳ —"
        case .notClockedIn: return "⏳ --:--"
        case .counting(let left): return "⏳ " + Formatting.hm(left)
        case .overtime(let weekly): return "OT " + Formatting.signedHM(weekly)
        }
    }
}
