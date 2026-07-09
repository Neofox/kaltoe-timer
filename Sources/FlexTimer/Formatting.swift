import Foundation

enum Formatting {
    /// "2:34" — floors to whole minutes, clamps negatives to "0:00".
    static func hm(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval)) / 60
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "-2:59" / "+0:12" — explicit sign, zero shown as "+0:00".
    static func signedHM(_ interval: TimeInterval) -> String {
        let m = Int(abs(interval)) / 60
        let sign = (interval < 0 && m > 0) ? "-" : "+"
        return sign + "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "2:34:12"
    static func hms(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return "\(s / 3600):" + String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
    }
}
