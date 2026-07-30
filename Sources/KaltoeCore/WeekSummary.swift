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
