import Foundation

struct WorkRules: Codable, Equatable {
    var dailyWork: TimeInterval = 8 * 3600       // net work target per day
    var breakTime: TimeInterval = 1 * 3600       // fixed lunch break
    var weeklyOvertime: TimeInterval = 5 * 3600  // required overtime per week
    var lunchStart: TimeInterval = 690 * 60      // official break start, seconds from midnight (11:30)
    var lunchEnd: TimeInterval = 750 * 60        // break end / work resumes (12:30)
    var lunchEarlyLeave: TimeInterval = 10 * 60  // allowed early departure to lunch
    var dayOffDeduction: TimeInterval = 1 * 3600     // weekly-required reduction per holiday/vacation weekday
    var familyDayEarlyLeave: TimeInterval = 2 * 3600 // family-day daily-target reduction; 0 disables family day
    var familyDayDeduction: TimeInterval = 1 * 3600  // weekly-required reduction for a family-day week
}

struct WorkRecord: Equatable {
    var clockIn: Date
    var clockOut: Date?                 // nil = still on the clock
    var flexWorkedNet: TimeInterval?    // net worked time as reported by Flex, if available
}

enum WorkCalculator {
    static func leaveTime(clockIn: Date, rules: WorkRules) -> Date {
        clockIn.addingTimeInterval(rules.dailyWork + rules.breakTime)
    }

    static func timeLeft(clockIn: Date, now: Date, rules: WorkRules) -> TimeInterval {
        leaveTime(clockIn: clockIn, rules: rules).timeIntervalSince(now)
    }

    /// Overtime contributed by one record. Completed day: net worked − daily target
    /// (both signs count). Open day: 0 until leave time, then accrues live.
    static func dailyOvertime(record: WorkRecord, now: Date, rules: WorkRules) -> TimeInterval {
        if let out = record.clockOut {
            let net = record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn) - rules.breakTime)
            return net - rules.dailyWork
        }
        return max(0, now.timeIntervalSince(leaveTime(clockIn: record.clockIn, rules: rules)))
    }

    /// Weekly counter: −required + Σ daily overtime. Negative = still owed.
    static func weeklyOvertime(records: [WorkRecord], now: Date, rules: WorkRules) -> TimeInterval {
        records.reduce(-rules.weeklyOvertime) { $0 + dailyOvertime(record: $1, now: now, rules: rules) }
    }

    /// Monday 00:00 of the week containing `date`.
    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)!.start
    }

    /// The lunch window on `day`: (moment you may leave for lunch, moment work resumes).
    /// Display only — does not affect leave time or overtime math.
    static func lunchWindow(on day: Date, rules: WorkRules,
                            calendar: Calendar = .current) -> (leaveAt: Date, endAt: Date) {
        let midnight = calendar.startOfDay(for: day)
        return (midnight.addingTimeInterval(rules.lunchStart - rules.lunchEarlyLeave),
                midnight.addingTimeInterval(rules.lunchEnd))
    }
}
