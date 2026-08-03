import SwiftUI
import KaltoeCore

/// One day of the week strip: label, bar, hours worked.
///
/// The bar is accent-coloured up to the day's target and orange past it, with a
/// notch at the target, so each row carries its own overtime rather than only
/// contributing to the total below. Hours worked sits on the right; signed overtime
/// would state the orange segment's fact twice and cost track width.
///
/// The track holds no space in reserve for overtime: on a week nobody ran over, the
/// scale is the longest target and a full bar means the day is done. On an ordinary
/// week that puts every row's notch at the track's right edge, where it reads as an
/// end cap — kept anyway, because a shortened day (family day, time off) carries its
/// notch inboard and that is the only thing on screen explaining why its bar stops
/// short of full.
struct WeekBarRow: View {
    let day: DaySummary
    /// Hours the full track spans. Passed in rather than held here because it is a
    /// property of the week, not of one day: `WeekSummary.barScale` derives it once
    /// from all five rows so they stay comparable, and every row must be handed the
    /// same value. See that property for why it is not a constant.
    let scale: TimeInterval

    /// Fixed rather than measured with a GeometryReader: the popover is a fixed
    /// 280pt, so 280 − 2×12 padding − 26 label − 36 value − 2×8 spacing = 178 is
    /// known here, and a reader would add a layout pass per row per second.
    private let trackWidth: CGFloat = 178
    private let trackHeight: CGFloat = 7

    var body: some View {
        HStack(spacing: 8) {
            Text(day.label)
                .font(.caption)
                .foregroundStyle(day.isOngoing ? Color.accentColor : Color.secondary)
                .frame(width: 26, alignment: .leading)
            track
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .opacity(emphasis)
        // One element with one sentence, or VoiceOver reads a label, an unnamed
        // shape and a bare number as three stops. The orange segment is the only
        // place overtime appears on screen, so it has to be spoken here.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// Emphasis for the whole row, brightest where it is live.
    ///
    /// The day you are on is the row you opened the popover to read, so it draws at
    /// full strength and finished days recede behind it. The dashed outline is what
    /// says "in progress" — a faded fill was the wrong signal for that, and having
    /// it on today alone made the live row the dimmest thing in the strip.
    ///
    /// Applied to the row rather than to each shape so a finished day's fill, its
    /// overtime segment and its figure all recede together.
    private var emphasis: Double {
        guard day.worked != nil else { return 0.55 }   // no record, or a day off
        return day.isOngoing ? 1 : 0.75
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
                .frame(width: trackWidth, height: trackHeight)
            if let worked = day.worked {
                // Today's remaining target, as an outline the fill grows into.
                if day.isOngoing {
                    Capsule()
                        .strokeBorder(Color.secondary.opacity(0.45),
                                      style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: x(day.target), height: trackHeight)
                }
                Capsule().fill(Color.accentColor)
                    .frame(width: x(min(worked, day.target)), height: trackHeight)
                if day.overtime > 0 {
                    Capsule().fill(Color.orange)
                        // Clamped against the remaining track, not just the scale:
                        // x() bounds the offset and the width separately, so their
                        // sum could otherwise run past 178pt and draw over the hours
                        // figure. `barScale` now sizes itself to fit target +
                        // overtime, so this should never bite — but that guarantee
                        // lives in another type and this is one `min` to keep it
                        // honest if the scale is ever computed some other way.
                        .frame(width: min(x(day.overtime), trackWidth - x(day.target)),
                               height: trackHeight)
                        .offset(x: x(day.target))
                }
            }
            Rectangle().fill(Color.secondary)
                .frame(width: 1, height: trackHeight + 6)
                .offset(x: x(day.target))
        }
        .frame(width: trackWidth, height: trackHeight)
    }

    private var value: String {
        if let worked = day.worked { return Formatting.hm(worked) }
        return day.isDayOff ? "off" : "·"
    }

    private var spokenLabel: String {
        guard let worked = day.worked else {
            return day.isDayOff ? "\(day.label), day off" : "\(day.label), no record"
        }
        // The target is stated in every case, not only when short of it. Sighted
        // users get it free from the notch's position — it is the reference point
        // that makes the bar mean anything — and without it VoiceOver hears a bare
        // number with nothing to judge it against.
        var text = "\(day.label), worked \(Formatting.hm(worked)) of \(Formatting.hm(day.target))"
        if day.overtime > 0 { text += ", \(Formatting.hm(day.overtime)) over target" }
        if day.isOngoing { text += ", still on the clock" }
        return text
    }

    /// Track offset for an interval, clamped to the track.
    private func x(_ interval: TimeInterval) -> CGFloat {
        min(trackWidth, max(0, trackWidth * CGFloat(interval / scale)))
    }
}
