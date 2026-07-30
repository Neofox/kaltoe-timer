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
        guard target < rules.dailyWork else { return nil }
        var reasons: [String] = []
        if rules.familyDayEarlyLeave > 0, WorkCalculator.isFamilyDay(day, calendar: calendar) {
            reasons.append("family day")
        }
        if off > 0 { reasons.append("time off") }
        // A reduced target with no nameable cause would render as a dangling
        // "Target 6:00 · ". Saying nothing is the better failure.
        guard !reasons.isEmpty else { return nil }
        return "Target \(Formatting.hm(target)) · " + reasons.joined(separator: ", ")
    }
}
