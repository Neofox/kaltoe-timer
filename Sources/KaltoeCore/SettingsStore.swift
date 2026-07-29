import Foundation

/// Rules and manual overrides, stored in UserDefaults so they are tweakable
/// without a rebuild (see README for `defaults write` commands).
public enum SettingsStore {
    public static var defaults = UserDefaults.standard

    public static var rules: WorkRules {
        var r = WorkRules()
        if let h = defaults.object(forKey: "dailyWorkHours") as? Double { r.dailyWork = h * 3600 }
        if let m = defaults.object(forKey: "breakMinutes") as? Double { r.breakTime = m * 60 }
        if let h = defaults.object(forKey: "weeklyOvertimeHours") as? Double { r.weeklyOvertime = h * 3600 }
        if let m = defaults.object(forKey: "lunchStartMinutes") as? Double { r.lunchStart = m * 60 }
        if let m = defaults.object(forKey: "lunchEndMinutes") as? Double { r.lunchEnd = m * 60 }
        if let m = defaults.object(forKey: "lunchEarlyLeaveMinutes") as? Double { r.lunchEarlyLeave = m * 60 }
        if let h = defaults.object(forKey: "dayOffDeductionHours") as? Double { r.dayOffDeduction = h * 3600 }
        if let h = defaults.object(forKey: "familyDayEarlyLeaveHours") as? Double { r.familyDayEarlyLeave = h * 3600 }
        if let h = defaults.object(forKey: "familyDayDeductionHours") as? Double { r.familyDayDeduction = h * 3600 }
        return r
    }

    /// Render the menu bar label as a non-template image so macOS cannot grey
    /// it out on the menu bar of an inactive display. Absent key reads false,
    /// so this is off by default with no registration needed.
    public static var highContrastOnInactiveDisplays: Bool {
        get { defaults.bool(forKey: "highContrastOnInactiveDisplays") }
        set { defaults.set(newValue, forKey: "highContrastOnInactiveDisplays") }
    }

    private static func key(for day: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "manualStart-" + df.string(from: day)
    }

    public static func manualStart(on day: Date) -> Date? {
        defaults.object(forKey: key(for: day)) as? Date
    }

    public static func setManualStart(_ date: Date?, on day: Date) {
        if let date { defaults.set(date, forKey: key(for: day)) }
        else { defaults.removeObject(forKey: key(for: day)) }
    }
}
