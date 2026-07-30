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

    /// Whole seconds truncated to the minute, toward zero — the invariant every
    /// interval on this wire obeys, in one place so it cannot be forgotten on the
    /// next field. `main.swift` emits on change, so a second-resolution interval
    /// would turn a once-per-minute emission into once per second — and on Plasma
    /// every emission drives a full tray-icon re-render (`_set_text_icon`).
    ///
    /// Toward zero rather than floor, matching `Formatting.signedHM`: pinned for
    /// `weekOvertime`, the only field here that can go negative, by
    /// `testWeekOvertimeRoundsToWholeMinutesTowardZero`.
    static func wholeMinutes(_ interval: TimeInterval) -> Int { Int(interval / 60) * 60 }

    /// One weekday for the tray. Every interval goes through `wholeMinutes`.
    public struct DayLine: Codable, Equatable, Sendable {
        public var label: String
        public var worked: Int?
        public var target: Int
        public var overtime: Int
        public var isDayOff: Bool
        public var isOngoing: Bool

        init(_ day: DaySummary) {
            label = day.label
            worked = day.worked.map(StatusLine.wholeMinutes)
            target = StatusLine.wholeMinutes(day.target)
            overtime = StatusLine.wholeMinutes(day.overtime)
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
        self.weekOvertime = weekOvertime.map(Self.wholeMinutes)
        self.days = summary?.days.map(DayLine.init)
        self.targetNote = summary?.targetNote
        self.weekOvertimeCap = summary.map { Self.wholeMinutes($0.cap) }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
