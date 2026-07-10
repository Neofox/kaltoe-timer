import Foundation

/// One NDJSON status line emitted by the kaltoe-core daemon and consumed by
/// the Linux tray (linux/kaltoe-tray.py). Field set is part of that contract;
/// nil optionals are omitted from the JSON.
public struct StatusLine: Codable, Equatable {
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

    public init(display: MenuDisplay, hasSession: Bool, lastSync: Date?, syncError: String?,
                started: Date? = nil, leaveAt: Date? = nil, weekOvertime: TimeInterval? = nil) {
        self.text = display.state.menuBarText
        self.icon = display.state.iconName
        self.urgency = display.urgency.rawValue
        self.hasSession = hasSession
        self.lastSync = lastSync
        self.syncError = syncError
        self.started = started
        self.leaveAt = leaveAt
        self.weekOvertime = weekOvertime.map { Int($0 / 60) * 60 }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
