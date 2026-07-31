import Foundation

/// Composes the popover's caption for a day whose target is shorter than usual.
///
/// The string is built here rather than per platform because the Linux tray is
/// Python and would otherwise carry a second copy of the wording, free to drift.
public enum TargetNote {
    /// "Target 4:00 · family day, time off", or nil when nothing shortened the day.
    public static func compose(on day: Date, rules: WorkRules, timeOff: [Date: TimeInterval],
                               calendar: Calendar = .current) -> String? {
        let off = WorkCalculator.timeOff(on: day, in: timeOff, calendar: calendar)
        let target = WorkCalculator.dailyTarget(on: day, rules: rules, timeOff: off,
                                                calendar: calendar)
        // Load-bearing, unlike the guard below: this is what rejects an ordinary
        // day, and it also absorbs a negative timeOff entry on a family day and a
        // dailyWork of 0, either of which would otherwise caption an unshortened day.
        guard target < rules.dailyWork else { return nil }
        var reasons: [String] = []
        if rules.familyDayEarlyLeave > 0, WorkCalculator.isFamilyDay(day, calendar: calendar) {
            reasons.append("family day")
        }
        if off > 0 { reasons.append("time off") }
        // Currently unreachable: every reduction dailyTarget applies is one of the
        // two named above, so passing the guard above implies a non-empty `reasons`.
        // It stands as a canary for the day a third reduction is added to
        // dailyTarget and not named here — at which point this line silently
        // swallows the whole caption and reproduces the very silent-shortening bug
        // the caption exists to cure. If it ever fires, name the new reason.
        guard !reasons.isEmpty else { return nil }
        return "Target \(Formatting.hm(target)) · " + reasons.joined(separator: ", ")
    }
}

/// One weekday in the week strip. Display-only: every field is derived, and
/// nothing here feeds the leave-time or overtime calculations.
public struct DaySummary: Equatable, Sendable {
    public var date: Date               // startOfDay
    public var label: String            // "Mon"
    public var worked: TimeInterval?    // nil = no record that day
    public var target: TimeInterval     // the bar's notch
    public var overtime: TimeInterval   // from dailyOvertime, floored at 0 — see netWorked
    public var isDayOff: Bool
    public var isOngoing: Bool

    public init(date: Date, label: String, worked: TimeInterval?, target: TimeInterval,
                overtime: TimeInterval, isDayOff: Bool, isOngoing: Bool) {
        self.date = date
        self.label = label
        self.worked = worked
        self.target = target
        self.overtime = overtime
        self.isDayOff = isDayOff
        self.isOngoing = isOngoing
    }
}

/// The whole week as the UI needs it, computed once per tick and consumed by the
/// menu bar pill, the popover and the daemon's status line — so the three cannot
/// disagree the way the popover and the pill previously could.
public struct WeekSummary: Equatable, Sendable {
    /// Always 5, Mon–Fri — in every value `compute` returns. Not in the
    /// default-initialised placeholder that `AppState.weekSummary` holds until the
    /// first `recompute`, which is empty.
    public var days: [DaySummary]
    public var overtime: TimeInterval
    public var cap: TimeInterval
    public var targetNote: String?
    public var todayIsDayOff: Bool

    public init(days: [DaySummary] = [], overtime: TimeInterval = 0, cap: TimeInterval = 0,
                targetNote: String? = nil, todayIsDayOff: Bool = false) {
        self.days = days
        self.overtime = overtime
        self.cap = cap
        self.targetNote = targetNote
        self.todayIsDayOff = todayIsDayOff
    }

    /// Weekday labels, fixed rather than locale-derived: the rest of this UI is
    /// English ("Started", "Leave at"), so a localised strip would be the only
    /// translated text on screen.
    private static let labels = ["Mon", "Tue", "Wed", "Thu", "Fri"]

    /// - Precondition: `calendar` must be `.current` (or omitted). It governs **row
    ///   layout only** — `weekStart`, each row's `startOfDay`, and the same-day match
    ///   that attaches a record to a row. Three things this function delegates to
    ///   ignore it entirely and always use `Calendar.current`:
    ///   `WorkCalculator.dailyOvertime` and `weeklyOvertime` take no `calendar`
    ///   parameter at all, so they re-derive the day's target on `.current`;
    ///   `WeekData.weekIncludingManual` hardcodes it for both its week filter and its
    ///   today check; and `dayOffDates` keys are normalised by `FlexRecordParser` on
    ///   `.current`, so `contains(key)` only matches when `key` was built the same way.
    ///
    ///   Pass anything else and a single row takes its `target` from `calendar` while
    ///   taking its `overtime` from a target computed on `.current` — a row that
    ///   contradicts itself, which is the exact class of defect this type exists to
    ///   prevent. The parameter is kept because it is the plan's signature and because
    ///   the layout half is genuinely injectable; closing the gap would mean threading
    ///   a calendar through `WorkCalculator`, which this feature is not allowed to
    ///   modify. Every current caller and test passes `.current`.
    public static func compute(from data: WeekData, now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> WeekSummary {
        // weekIncludingManual, not `records`, so a manual start appears as a row
        // exactly as it already counts toward the total.
        let records = data.weekIncludingManual(now: now)
        let weekStart = WorkCalculator.weekStart(of: now, calendar: calendar)
        // Five rows, Mon–Fri, always — weekends are deliberately not modelled, and
        // since `dailyOvertime` returns 0 for a weekend record the rows and the total
        // beneath them agree. Pinned by
        // `testWeekendRecordEarnsNoOvertimeAndHasNoRow`.
        let days = Self.labels.indices.map { offset -> DaySummary in
            let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            let key = calendar.startOfDay(for: day)
            let off = WorkCalculator.timeOff(on: day, in: data.timeOff, calendar: calendar)
            let target = WorkCalculator.dailyTarget(on: day, rules: rules, timeOff: off,
                                                    calendar: calendar)
            let record = records.first { calendar.isDate($0.clockIn, inSameDayAs: day) }
            let worked = record.map {
                netWorked($0, target: target, now: now, rules: rules, timeOff: off,
                          calendar: calendar)
            }
            return DaySummary(date: key, label: Self.labels[offset], worked: worked,
                              target: target,
                              // The same function that feeds weeklyOvertime, floored
                              // the same way, so a row cannot contradict the total
                              // printed beneath it. Deriving it from `worked` instead
                              // looks equivalent and is not: see netWorked below.
                              overtime: record.map {
                                  max(0, WorkCalculator.dailyOvertime(record: $0, now: now,
                                                                      rules: rules,
                                                                      timeOff: data.timeOff))
                              } ?? 0,
                              isDayOff: data.dayOffDates.contains(key),
                              isOngoing: record.map { $0.clockOut == nil } ?? false)
        }
        return WeekSummary(
            days: days,
            overtime: WorkCalculator.weeklyOvertime(records: records, timeOff: data.timeOff,
                                                    now: now, rules: rules),
            cap: rules.weeklyOvertimeCap,
            targetNote: TargetNote.compose(on: now, rules: rules, timeOff: data.timeOff,
                                           calendar: calendar),
            todayIsDayOff: days.first { calendar.isDate($0.date, inSameDayAs: now) }?
                .isDayOff ?? false)
    }

    /// Net hours worked — the bar's length and the row's right-hand figure only.
    /// Completed days mirror `dailyOvertime`'s derivation; open days deduct only the
    /// break already spent, so the figure rises from clock-in rather than starting an
    /// hour in the hole.
    ///
    /// **This is deliberately not the source of the row's overtime.** It is tempting
    /// to write `max(0, worked - target)` and call it the same thing, and it is not:
    /// clock in after the lunch window closes and `breakTaken` stays 0 forever while
    /// `leaveTime` still adds the full break. A 13:00 start with an 8h target is due
    /// out at 22:00, so at 22:30 `worked - target` reads +1:30 where `dailyOvertime`
    /// reads +0:30 — and the row would contradict the weekly total directly beneath
    /// it, which is the failure the signed-overtime layout was rejected to avoid.
    /// `overtime` therefore comes from `dailyOvertime` above.
    ///
    /// The consequence, accepted, and it belongs to the **accent fill**, not the
    /// orange one: the fill is drawn from `worked` against `target`, and after a
    /// start past the lunch window `worked` carries no break deduction, so the fill
    /// can reach the notch up to a full break early while the pill is still counting
    /// down. The orange segment is not affected — its width is `overtime`, i.e.
    /// `dailyOvertime`, the same figure the pill uses, so it agrees with the pill and
    /// if anything lags it. The numbers stay consistent; only the fill is early.
    private static func netWorked(_ record: WorkRecord, target: TimeInterval, now: Date,
                                  rules: WorkRules, timeOff: TimeInterval,
                                  calendar: Calendar) -> TimeInterval {
        if let out = record.clockOut {
            return record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn)
                          - WorkCalculator.breakDuration(target: target, rules: rules))
        }
        return max(0, now.timeIntervalSince(record.clockIn)
                      - WorkCalculator.breakTaken(clockIn: record.clockIn, now: now, rules: rules,
                                                  timeOff: timeOff, calendar: calendar))
    }
}
