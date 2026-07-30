import Foundation

/// One NDJSON status line emitted by the kaltoe-core daemon and consumed by
/// the Linux tray (linux/kaltoe-tray.py). Field set is part of that contract;
/// nil optionals are omitted from the JSON.
public struct StatusLine: Codable, Equatable, Sendable {
    public var text: String
    public var icon: String
    public var urgency: String
    public var hasSession: Bool
    public var lastSync: Date?
    public var syncError: String?
    /// Detail rows for the tray menu (Mac-dropdown parity). Omitted when
    /// signed out / not clocked in.
    public var started: Date?
    public var leaveAt: Date?
    /// Weekly overtime in seconds, truncated to the whole minute so the
    /// daemon's change-driven emission stays minute-cadenced.
    public var weekOvertime: Int?
    /// The week strip, minute-truncated. Omitted when signed out, like the rows above.
    public var days: [DayLine]?
    /// "Target 4:00 · family day, time off" — nil unless today's target is reduced.
    public var targetNote: String?
    /// The weekly overtime ceiling, so the tray can render "/ 12:00" as the
    /// popover does rather than a bare total.
    public var weekOvertimeCap: Int?

    /// **Seconds**, with the sub-minute part dropped — 3660 in, 3600 out, not 61.
    /// The invariant every interval on this wire obeys, in one place so it cannot be
    /// forgotten on the next field added. `main.swift` emits on change, so without it
    /// a second-resolution interval would move on every tick — sixty emissions a
    /// minute instead of the one or two below, and on Plasma every emission drives a
    /// full tray-icon render/write/unlink cycle (`kaltoe-tray.py:_set_text_icon`).
    ///
    /// One or two, deliberately: truncation makes each *field* minute-cadenced, not
    /// the line as a whole. `weekOvertime` floors the **sum**, so prior days'
    /// fractional seconds offset its minute boundary from the clock-in-aligned
    /// fields, and the overtime phase has therefore emitted twice a minute since
    /// before this week strip existed. What the invariant buys is the 60× reduction,
    /// not a single emission per minute.
    ///
    /// "Floored" is loose for negatives: the rounding is toward zero, so −250 gives
    /// −240, not −300. That matches `Formatting.signedHM`, and it is pinned for
    /// `weekOvertime` by
    /// `StatusLineTests.testWeekOvertimeRoundsToWholeMinutesTowardZero`. `weekOvertime`
    /// is not the only field here that can go negative, and the other one matters for
    /// exactly the reason the next paragraph raises: `weekOvertimeCap` copies
    /// `rules.weeklyOvertimeCap` with no floor, so `weeklyOvertimeCapHours -float -5`
    /// puts a negative denominator on the wire — where the tray's `hm` clamps it and
    /// renders a confident, wrong `/ 0:00`.
    ///
    /// Total by construction. `Int(Double)` **traps** on NaN, ±infinity or an
    /// out-of-range magnitude, and this is reachable from hostile settings rather
    /// than only from bad arithmetic: `SettingsStore.rules` reads `dailyWorkHours`
    /// and `weeklyOvertimeCapHours` as raw `Double` and multiplies, so a typo in the
    /// `defaults write` line README documents would otherwise crash-loop the daemon.
    /// Garbage in yields 0 — a visibly wrong row beats no daemon at all.
    static func secondsFlooredToMinute(_ interval: TimeInterval) -> Int {
        // `rounded(.towardZero)` first, so `Int(exactly:)` only ever rejects the
        // non-finite and the genuinely out-of-range, never a fractional value.
        guard let minutes = Int(exactly: (interval / 60).rounded(.towardZero)) else { return 0 }
        let (seconds, overflowed) = minutes.multipliedReportingOverflow(by: 60)
        return overflowed ? 0 : seconds
    }

    /// One weekday for the tray. Every interval goes through
    /// `secondsFlooredToMinute`.
    public struct DayLine: Codable, Equatable, Sendable {
        public var label: String
        public var worked: Int?
        public var target: Int
        public var overtime: Int
        public var isDayOff: Bool
        public var isOngoing: Bool

        init(_ day: DaySummary) {
            label = day.label
            worked = day.worked.map(StatusLine.secondsFlooredToMinute)
            target = StatusLine.secondsFlooredToMinute(day.target)
            overtime = StatusLine.secondsFlooredToMinute(day.overtime)
            isDayOff = day.isDayOff
            isOngoing = day.isOngoing
        }
    }

    public init(display: MenuDisplay, hasSession: Bool, lastSync: Date?, syncError: String?,
                started: Date? = nil, leaveAt: Date? = nil, weekOvertime: TimeInterval? = nil,
                summary: WeekSummary? = nil) {
        self.text = display.state.menuBarText
        self.icon = display.state.iconName
        self.urgency = display.urgency.rawValue
        self.hasSession = hasSession
        self.lastSync = lastSync
        self.syncError = syncError
        self.started = started
        self.leaveAt = leaveAt
        self.weekOvertime = weekOvertime.map(Self.secondsFlooredToMinute)
        self.days = summary?.days.map(DayLine.init)
        self.targetNote = summary?.targetNote
        self.weekOvertimeCap = summary.map { Self.secondsFlooredToMinute($0.cap) }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
