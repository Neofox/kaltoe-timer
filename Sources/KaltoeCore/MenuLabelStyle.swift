import Foundation

/// How the menu bar label should be drawn.
///
/// `.plain` is a template view, which macOS greys out on the menu bar of a
/// display that does not hold the active window. `.solid` and `.pill` are
/// pre-rendered non-template images, which it leaves alone — that is the whole
/// point of the high-contrast setting.
public enum MenuLabelStyle: Equatable, Sendable {
    /// Template icon + text. Default appearance.
    case plain
    /// Non-template icon + text in a solid, appearance-matched colour.
    case solid
    /// Non-template capsule for the alerting states.
    case pill(Urgency)

    /// Urgency wins over the contrast preference: an alerting state always
    /// keeps its coloured pill, so the setting can never suppress it.
    public static func resolve(urgency: Urgency, highContrast: Bool) -> MenuLabelStyle {
        switch urgency {
        case .warning, .critical: return .pill(urgency)
        case .normal: return highContrast ? .solid : .plain
        }
    }
}
