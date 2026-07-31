import Foundation

public enum Formatting {
    /// "2:34" — floors to whole minutes, clamps negatives to "0:00".
    ///
    /// Total. `Int(Double)` **traps** on NaN and on the infinities, and the conversion
    /// happens before the clamp can help, so the guard is a crash guard rather than
    /// tidiness. It is reachable: `rules.weeklyOvertimeCap` comes from
    /// `weeklyOvertimeCapHours`, a raw `Double` in `UserDefaults` that the README
    /// documents a `defaults write` for, and `MenuBarView` hands the cap straight to this
    /// function. `StatusLine.secondsFlooredToMinute` was hardened against exactly this;
    /// the popover was not, so `-float nan` crash-looped the app on input the daemon
    /// already survived.
    public static func hm(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00" }
        let m = max(0, Int(interval)) / 60
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "-2:59" / "+0:12" — explicit sign, zero shown as "+0:00".
    ///
    /// Same trap as `hm`, via `Int(abs(interval))`. Non-finite yields "+0:00", matching
    /// how a genuine zero renders.
    public static func signedHM(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "+0:00" }
        let m = Int(abs(interval)) / 60
        let sign = (interval < 0 && m > 0) ? "-" : "+"
        return sign + "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "2:34:12"
    ///
    /// Same trap as `hm`. Non-finite yields "0:00:00", matching the negative clamp.
    public static func hms(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00:00" }
        let s = max(0, Int(interval))
        return "\(s / 3600):" + String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
    }
}
