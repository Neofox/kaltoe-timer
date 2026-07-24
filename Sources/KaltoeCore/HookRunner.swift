import Foundation

/// Runs user hook scripts on detected 출근/퇴근, at most once per event per day.
///
/// Scripts are optional executables in `~/Library/Application Support/칼퇴타이머/hooks/`
/// on macOS, `~/.config/kaltoe-timer/hooks/` on Linux (`on-clock-in`, `on-clock-out`).
/// Dedupe state persists in UserDefaults as `hookFired-<event>-yyyy-MM-dd`, so app
/// restarts never re-fire, but an app launched after the real event still fires
/// once (late detection).
public final class HookRunner {
    public static var hooksDirectory: URL {
        #if os(macOS)
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("칼퇴타이머/hooks", isDirectory: true)
        #else
        LinuxPaths.configDirectory.appendingPathComponent("hooks", isDirectory: true)
        #endif
    }

    private let defaults: UserDefaults
    private let execute: (URL, [String: String]) -> Void
    private let iso = ISO8601DateFormatter()

    public init(defaults: UserDefaults = SettingsStore.defaults,
         execute: @escaping (URL, [String: String]) -> Void = HookRunner.launchDetached) {
        self.defaults = defaults
        self.execute = execute
    }

    public func evaluate(today: WorkRecord?, now: Date) {
        guard let record = today else { return }
        let day = Self.dayString(now)
        if markFiredIfNeeded("clockIn", day: day) {
            execute(Self.hooksDirectory.appendingPathComponent("on-clock-in"),
                    ["KALTOE_EVENT": "clock-in",
                     "KALTOE_CLOCK_IN": iso.string(from: record.clockIn)])
        }
        if let clockOut = record.clockOut, markFiredIfNeeded("clockOut", day: day) {
            execute(Self.hooksDirectory.appendingPathComponent("on-clock-out"),
                    ["KALTOE_EVENT": "clock-out",
                     "KALTOE_CLOCK_IN": iso.string(from: record.clockIn),
                     "KALTOE_CLOCK_OUT": iso.string(from: clockOut)])
        }
    }

    /// True if the event had not fired today; marks it fired and drops stale keys.
    private func markFiredIfNeeded(_ event: String, day: String) -> Bool {
        let key = "hookFired-\(event)-\(day)"
        guard defaults.object(forKey: key) == nil else { return false }
        for stale in defaults.dictionaryRepresentation().keys
        where stale.hasPrefix("hookFired-") && !stale.hasSuffix(day) {
            defaults.removeObject(forKey: stale)
        }
        defaults.set(true, forKey: key)
        #if !os(macOS)
        // Linux corelibs never flushes UserDefaults on set(); without this,
        // hooks re-fire on every daemon restart.
        defaults.synchronize()
        #endif
        return true
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Fire-and-forget: launch the script detached, never wait or read output.
    /// Missing or non-executable script is silently skipped. Backgrounded
    /// children (e.g. `caffeinate &`) survive after the script exits.
    public static func launchDetached(_ script: URL, _ env: [String: String]) {
        guard FileManager.default.isExecutableFile(atPath: script.path) else { return }
        let process = Process()
        process.executableURL = script
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, hook in hook }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
