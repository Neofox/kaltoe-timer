import SwiftUI
import KaltoeCore

/// One day of the week strip: label, bar, hours worked.
///
/// The bar is blue up to the day's target and orange past it, with a notch at the
/// target, so each row carries its own overtime rather than only contributing to
/// the total below. Hours worked sits on the right; signed overtime would state
/// the orange segment's fact twice and cost track width.
struct WeekBarRow: View {
    let day: DaySummary

    /// Fixed rather than measured with a GeometryReader: the popover is a fixed
    /// 280pt, so 280 − 2×12 padding − 26 label − 36 value − 2×8 spacing = 178 is
    /// known here, and a reader would add a layout pass per row per second.
    private let trackWidth: CGFloat = 178
    private let trackHeight: CGFloat = 7
    /// Hours the full track spans, shared by every row so they are comparable.
    private let scale: TimeInterval = 10 * 3600

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
        .opacity(day.worked == nil ? 0.55 : 1)
        // One element with one sentence, or VoiceOver reads a label, an unnamed
        // shape and a bare number as three stops. The orange segment is the only
        // place overtime appears on screen, so it has to be spoken here.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
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
                Capsule().fill(Color.accentColor.opacity(day.isOngoing ? 0.55 : 1))
                    .frame(width: x(min(worked, day.target)), height: trackHeight)
                if day.overtime > 0 {
                    Capsule().fill(Color.orange)
                        .frame(width: x(day.overtime), height: trackHeight)
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
        var text = "\(day.label), worked \(Formatting.hm(worked))"
        if day.overtime > 0 { text += ", \(Formatting.hm(day.overtime)) over target" }
        if day.isOngoing { text += ", still on the clock" }
        return text
    }

    /// Track offset for an interval, clamped to the track.
    private func x(_ interval: TimeInterval) -> CGFloat {
        min(trackWidth, max(0, trackWidth * CGFloat(interval / scale)))
    }
}
