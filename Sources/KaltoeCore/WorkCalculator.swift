import Foundation

public struct WorkRules: Codable, Equatable {
    public var dailyWork: TimeInterval = 8 * 3600       // net work target per day
    public var breakTime: TimeInterval = 1 * 3600       // fixed lunch break
    public var weeklyOvertimeCap: TimeInterval = 12 * 3600  // max overtime allowed per week
    public var overtimeCutoff: TimeInterval = 22 * 3600     // no overtime past this, seconds from midnight
    public var lunchStart: TimeInterval = 690 * 60      // official break start, seconds from midnight (11:30)
    public var lunchEnd: TimeInterval = 750 * 60        // break end / work resumes (12:30)
    public var lunchEarlyLeave: TimeInterval = 10 * 60  // allowed early departure to lunch
    public var familyDayEarlyLeave: TimeInterval = 2 * 3600 // family-day daily-target reduction; 0 disables family day

    public init() {}

}

public struct WorkRecord: Equatable {
    public var clockIn: Date
    public var clockOut: Date?                 // nil = still on the clock
    public var flexWorkedNet: TimeInterval?    // net worked time as reported by Flex, if available

    public init(clockIn: Date, clockOut: Date?, flexWorkedNet: TimeInterval?) {
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.flexWorkedNet = flexWorkedNet
    }
}

public enum WorkCalculator {
    public static func leaveTime(clockIn: Date, rules: WorkRules, timeOff: TimeInterval = 0) -> Date {
        let target = dailyTarget(on: clockIn, rules: rules, timeOff: timeOff)
        return clockIn.addingTimeInterval(target + breakDuration(target: target, rules: rules))
    }

    public static func timeLeft(clockIn: Date, now: Date, rules: WorkRules, timeOff: TimeInterval = 0) -> TimeInterval {
        leaveTime(clockIn: clockIn, rules: rules, timeOff: timeOff).timeIntervalSince(now)
    }

    /// The day's break: full lunch normally; none when approved time off cuts
    /// the target to a half day or less (per policy: a 4h half-day has no lunch).
    public static func breakDuration(target: TimeInterval, rules: WorkRules) -> TimeInterval {
        target > rules.dailyWork / 2 ? rules.breakTime : 0
    }

    /// Approved time-off seconds for the day containing `day` (0 if none).
    /// `map` keys must be `startOfDay`-normalized (parser convention).
    public static func timeOff(on day: Date, in map: [Date: TimeInterval],
                        calendar: Calendar = .current) -> TimeInterval {
        map[calendar.startOfDay(for: day)] ?? 0
    }

    /// Overtime contributed by one record. Completed day: net worked − daily target
    /// (both signs count; the target is family-day- and time-off-aware). Open day:
    /// 0 until leave time, then accrues live.
    public static func dailyOvertime(record: WorkRecord, now: Date, rules: WorkRules,
                              timeOff: [Date: TimeInterval] = [:]) -> TimeInterval {
        let off = Self.timeOff(on: record.clockIn, in: timeOff)
        let target = dailyTarget(on: record.clockIn, rules: rules, timeOff: off)
        if let out = record.clockOut {
            let net = record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn) - breakDuration(target: target, rules: rules))
            return net - target
        }
        return max(0, now.timeIntervalSince(leaveTime(clockIn: record.clockIn, rules: rules, timeOff: off)))
    }

    /// Overtime worked this week: the sum of each day's overtime, floored at
    /// zero per day. A day worked short of target contributes nothing rather
    /// than offsetting a long day — "hours over the target" cannot be negative.
    /// `timeOff` keys must be `Calendar.current.startOfDay`-normalized dates.
    public static func weeklyOvertime(records: [WorkRecord],
                                      timeOff: [Date: TimeInterval] = [:],
                                      now: Date, rules: WorkRules) -> TimeInterval {
        records.reduce(0) {
            $0 + max(0, dailyOvertime(record: $1, now: now, rules: rules, timeOff: timeOff))
        }
    }

    /// Family day: the last Friday of the calendar month (disabled when
    /// rules.familyDayEarlyLeave == 0 — callers check that, not this).
    public static func isFamilyDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.weekday, from: date) == 6 else { return false } // Friday
        guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: date) else { return false }
        return !calendar.isDate(nextWeek, equalTo: date, toGranularity: .month)   // +7d leaves the month
    }

    /// Net work target for a given day: dailyWork, reduced on family day, then
    /// reduced by approved time off; floored at 0.
    public static func dailyTarget(on day: Date, rules: WorkRules, timeOff: TimeInterval = 0,
                            calendar: Calendar = .current) -> TimeInterval {
        var target = rules.dailyWork
        if rules.familyDayEarlyLeave > 0, isFamilyDay(day, calendar: calendar) {
            target -= rules.familyDayEarlyLeave
        }
        return max(0, target - timeOff)
    }

    /// True once `now` is at or past the day's overtime cutoff. This is the
    /// only wall-clock rule in the model — overtime itself is measured from
    /// clock-in, so a 07:00 start and a 09:00 start accrue identically.
    public static func isPastOvertimeCutoff(now: Date, rules: WorkRules,
                                            calendar: Calendar = .current) -> Bool {
        now.timeIntervalSince(calendar.startOfDay(for: now)) >= rules.overtimeCutoff
    }

    /// True once the week's overtime has reached the allowed ceiling.
    public static func hasReachedWeeklyCap(weeklyOvertime: TimeInterval,
                                           rules: WorkRules) -> Bool {
        weeklyOvertime >= rules.weeklyOvertimeCap
    }

    /// Monday 00:00 of the week containing `date`.
    public static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)!.start
    }

    /// The lunch window on `day`: (moment you may leave for lunch, moment work resumes).
    /// Display only — does not affect leave time or overtime math.
    public static func lunchWindow(on day: Date, rules: WorkRules,
                            calendar: Calendar = .current) -> (leaveAt: Date, endAt: Date) {
        let midnight = calendar.startOfDay(for: day)
        return (midnight.addingTimeInterval(rules.lunchStart - rules.lunchEarlyLeave),
                midnight.addingTimeInterval(rules.lunchEnd))
    }
}
