import Foundation

public enum Urgency: String, Equatable, Sendable {
    case normal, warning, critical
}

public struct MenuDisplay: Equatable, Sendable {
    public var state: DisplayState
    public var urgency: Urgency

    public init(state: DisplayState, urgency: Urgency) {
        self.state = state
        self.urgency = urgency
    }
}

public enum DisplayState: Equatable, Sendable {
    case noSession
    case notClockedIn
    case toLunch(timeLeft: TimeInterval)   // counting down to the lunch-leave moment
    case onBreak(timeLeft: TimeInterval)   // counting down to work resuming
    case counting(timeLeft: TimeInterval)  // counting down to leave time
    case overtime(today: TimeInterval)   // overtime worked today; negative if short

    private static let warningThreshold: TimeInterval = 30 * 60
    private static let criticalThreshold: TimeInterval = 10 * 60

    /// Smart single value with day phases and an overwork urgency level.
    ///
    /// `weeklyOvertime` is supplied by the caller rather than derived here.
    /// Both callers already compute it for their own purposes, and `recompute`
    /// runs every second — deriving it again inside this function was pure
    /// waste. Taking it as a parameter also removes the need for `week`, which
    /// fed nothing else.
    public static func computeDisplay(hasSession: Bool, today: WorkRecord?,
                               weeklyOvertime: TimeInterval,
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
        let todayOvertime = WorkCalculator.dailyOvertime(record: today, now: now,
                                                         rules: rules, timeOff: timeOff)
        let clockedIn = today.clockOut == nil
        let urgency: Urgency
        if WorkCalculator.hasReachedWeeklyCap(weeklyOvertime: weeklyOvertime, rules: rules) {
            urgency = .critical                     // cap applies on or off the clock
        } else if clockedIn, WorkCalculator.isPastOvertimeCutoff(now: now, rules: rules,
                                                                 calendar: calendar) {
            urgency = .critical                     // working past the cutoff
        } else if clockedIn {
            urgency = .warning                      // in overtime, within both limits
        } else {
            urgency = .normal                       // day settled
        }
        return MenuDisplay(state: .overtime(today: todayOvertime), urgency: urgency)
    }

    public var menuBarText: String {
        switch self {
        case .noSession: return "—"
        case .notClockedIn: return "--:--"
        case .toLunch(let left): return Formatting.hm(left)
        case .onBreak(let left): return "BREAK " + Formatting.hm(left)
        case .counting(let left): return Formatting.hm(left)
        case .overtime(let today): return "OT " + Formatting.signedHM(today)
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
