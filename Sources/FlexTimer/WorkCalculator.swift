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
        clockIn.addingTimeInterval(dailyTarget(on: clockIn, rules: rules) + rules.breakTime)
    }

    static func timeLeft(clockIn: Date, now: Date, rules: WorkRules) -> TimeInterval {
        leaveTime(clockIn: clockIn, rules: rules).timeIntervalSince(now)
    }

    /// Overtime contributed by one record. Completed day: net worked − daily target
    /// (both signs count; the target is family-day-aware). Open day: 0 until leave
    /// time, then accrues live.
    static func dailyOvertime(record: WorkRecord, now: Date, rules: WorkRules) -> TimeInterval {
        if let out = record.clockOut {
            let net = record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn) - rules.breakTime)
            return net - dailyTarget(on: record.clockIn, rules: rules)
        }
        return max(0, now.timeIntervalSince(leaveTime(clockIn: record.clockIn, rules: rules)))
    }

    /// Weekly counter: −(adjusted required) + Σ daily overtime. Negative = still owed.
    /// `dayOffs` elements must be `Calendar.current.startOfDay`-normalized dates —
    /// week-range filtering compares instants.
    static func weeklyOvertime(records: [WorkRecord], dayOffs: Set<Date> = [],
                               now: Date, rules: WorkRules) -> TimeInterval {
        records.reduce(-requiredOvertime(dayOffs: dayOffs, weekOf: now, rules: rules)) {
            $0 + dailyOvertime(record: $1, now: now, rules: rules)
        }
    }

    /// Family day: the last Friday of the calendar month (disabled when
    /// rules.familyDayEarlyLeave == 0 — callers check that, not this).
    static func isFamilyDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.weekday, from: date) == 6 else { return false } // Friday
        guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: date) else { return false }
        return !calendar.isDate(nextWeek, equalTo: date, toGranularity: .month)   // +7d leaves the month
    }

    /// Net work target for a given day: dailyWork, reduced on family day.
    static func dailyTarget(on day: Date, rules: WorkRules, calendar: Calendar = .current) -> TimeInterval {
        guard rules.familyDayEarlyLeave > 0, isFamilyDay(day, calendar: calendar) else { return rules.dailyWork }
        return rules.dailyWork - rules.familyDayEarlyLeave
    }

    /// Required overtime for the week containing `now`: base − dayOffDeduction per
    /// holiday/vacation weekday − familyDayDeduction if the week contains family day
    /// (family day itself never double-counts as a day-off). Floored at 0.
    /// `dayOffs` elements must be `Calendar.current.startOfDay`-normalized dates —
    /// week-range filtering compares instants.
    static func requiredOvertime(dayOffs: Set<Date>, weekOf now: Date, rules: WorkRules,
                                 calendar: Calendar = .current) -> TimeInterval {
        let start = weekStart(of: now, calendar: calendar)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return rules.weeklyOvertime }
        var required = rules.weeklyOvertime
        var familyDay: Date?
        if rules.familyDayEarlyLeave > 0,
           let friday = calendar.date(byAdding: .day, value: 4, to: start),  // Mon-start week → Friday
           isFamilyDay(friday, calendar: calendar) {
            familyDay = friday
            required -= rules.familyDayDeduction
        }
        let deductionDays = dayOffs
            .filter { $0 >= start && $0 < end }
            .filter { day in familyDay.map { !calendar.isDate(day, inSameDayAs: $0) } ?? true }
        required -= rules.dayOffDeduction * Double(deductionDays.count)
        return max(0, required)
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
