import Foundation

public enum Urgency: String, Equatable {
    case normal, warning, critical
}

public struct MenuDisplay: Equatable {
    public var state: DisplayState
    public var urgency: Urgency

    public init(state: DisplayState, urgency: Urgency) {
        self.state = state
        self.urgency = urgency
    }
}

public enum DisplayState: Equatable {
    case noSession
    case notClockedIn
    case toLunch(timeLeft: TimeInterval)   // counting down to the lunch-leave moment
    case onBreak(timeLeft: TimeInterval)   // counting down to work resuming
    case counting(timeLeft: TimeInterval)  // counting down to leave time
    case overtime(weekly: TimeInterval)

    private static let warningThreshold: TimeInterval = 30 * 60
    private static let criticalThreshold: TimeInterval = 10 * 60

    /// Smart single value with day phases and an overwork urgency level.
    public static func computeDisplay(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                               dayOffs: Set<Date> = [],
                               timeOff: [Date: TimeInterval] = [:],
                               now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> MenuDisplay {
        guard hasSession else { return MenuDisplay(state: .noSession, urgency: .normal) }
        guard let today else { return MenuDisplay(state: .notClockedIn, urgency: .normal) }
        let off = WorkCalculator.timeOff(on: today.clockIn, in: timeOff, calendar: calendar)
        let left = WorkCalculator.timeLeft(clockIn: today.clockIn, now: now, rules: rules, timeOff: off)
        if today.clockOut == nil && left > 0 {
            let lunch = WorkCalculator.lunchWindow(on: now, rules: rules, calendar: calendar)
            let leave = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules, timeOff: off)
            if leave > lunch.endAt { // lunch phases only apply to a normally-shaped day
                if now < lunch.leaveAt {
                    return MenuDisplay(state: .toLunch(timeLeft: lunch.leaveAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
                if now < lunch.endAt {
                    return MenuDisplay(state: .onBreak(timeLeft: lunch.endAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
            }
            let urgency: Urgency = left <= criticalThreshold ? .critical
                : left <= warningThreshold ? .warning : .normal
            return MenuDisplay(state: .counting(timeLeft: left), urgency: urgency)
        }
        let weekly = WorkCalculator.weeklyOvertime(records: week, dayOffs: dayOffs,
                                                   timeOff: timeOff, now: now, rules: rules)
        // Past leave time with the day still open = overworking right now.
        return MenuDisplay(state: .overtime(weekly: weekly),
                           urgency: today.clockOut == nil ? .critical : .normal)
    }

    /// v1 compatibility wrapper — state only.
    public static func compute(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                        now: Date, rules: WorkRules) -> DisplayState {
        computeDisplay(hasSession: hasSession, today: today, week: week,
                       now: now, rules: rules).state
    }

    public var menuBarText: String {
        switch self {
        case .noSession: return "—"
        case .notClockedIn: return "--:--"
        case .toLunch(let left): return Formatting.hm(left)
        case .onBreak(let left): return "BREAK " + Formatting.hm(left)
        case .counting(let left): return Formatting.hm(left)
        case .overtime(let weekly): return "OT " + Formatting.signedHM(weekly)
        }
    }

    public var iconName: String {
        switch self {
        case .toLunch: return "fork.knife"
        case .onBreak: return "cup.and.saucer"
        case .noSession, .notClockedIn, .counting, .overtime: return "timer"
        }
    }
}
