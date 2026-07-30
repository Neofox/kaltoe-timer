import AppKit
import SwiftUI
import KaltoeCore

/// Menu bar label: a pre-rendered non-template `NSImage` in every state, drawn as
/// either a progress Ring around the glyph or a filling Track capsule behind the
/// whole label.
///
/// Non-template is the entire mechanism, and it is now unconditional. macOS greys
/// out template images on the menu bar of a display that does not hold the active
/// window, and also ignores colours on plain label views — rasterising sidesteps
/// both. That is why there is no longer a high-contrast preference: its benefit
/// applies always.
struct MenuBarLabel: View {
    let display: MenuDisplay
    let text: String
    /// 0…1, from `WorkCalculator.dayProgress`. Already clamped and finite.
    let progress: Double
    let geometry: LabelGeometry

    /// Resolves against the menu bar's own appearance, so every colour opposes
    /// whatever the bar is drawn in.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: rendered())
            .accessibilityLabel(spoken)
    }

    private var phase: LabelPhase { LabelPhase(display) }

    private var colours: LabelPalette.Colours {
        LabelPalette.resolve(progress: progress, phase: phase)
    }

    /// `.noSession` draws the glyph alone with no text, so VoiceOver would
    /// otherwise reach a nameless image.
    private var spoken: String {
        text.isEmpty ? "Signed out" : text
    }

    /// How much of the arc or capsule to fill. `progress` everywhere except past
    /// target, which fills completely however far `progress` got.
    ///
    /// Not cosmetic. Time off at or above the day's target drives the target to
    /// zero, so `leaveTime == clockIn`, the span is zero, and `dayProgress` returns
    /// 0 by its totality guard — while such a day has no time left and so is
    /// `.overtime` from the first tick. Driving the fill from `progress` there would
    /// draw an empty ring in overtime orange, which reads as broken rather than as
    /// past target. In the ordinary case this changes nothing: being past leave time
    /// already clamps `progress` to 1. `.settled` stays progress-driven deliberately
    /// — a short day's partly-filled ring is the whole point of that state.
    private var fillFraction: Double {
        switch phase {
        case .overtime, .atLimit: return 1
        case .idle, .working, .settled: return progress
        }
    }

    /// Resolves a fill. The `.system` cases are the whole reason `LabelFill` exists:
    /// they return the very colours the popover already draws, so the label's
    /// over-target orange **is** the week strip's orange rather than a tuned
    /// near-neighbour. `KaltoeCore` cannot name a SwiftUI colour, so it names the
    /// intent and this resolves it.
    private func colour(_ fill: LabelFill) -> Color {
        switch fill {
        case .pair(let pair): return colour(pair)
        case .systemOrange: return .orange
        case .systemRed: return .red
        }
    }

    private func colour(_ pair: ColourPair) -> Color {
        let c = colorScheme == .dark ? pair.dark : pair.light
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    private var barForeground: Color { colorScheme == .dark ? .white : .black }

    private var glyphColour: Color {
        // Not `map(colour)` — `colour` is overloaded, so the closure is ambiguous.
        guard let tint = colours.glyphTint else { return barForeground }
        return colour(tint)
    }

    // MARK: geometry

    private let ringSize: CGFloat = 14
    private let ringStroke: CGFloat = 2

    private var ring: some View {
        ZStack {
            Circle()
                .inset(by: ringStroke / 2)
                .stroke(colour(colours.track),
                        style: StrokeStyle(lineWidth: ringStroke, lineCap: .round,
                                           dash: colours.dashed ? [1.5, 2.0] : []))
            if !colours.dashed {
                Circle()
                    .inset(by: ringStroke / 2)
                    .trim(from: 0, to: fillFraction)
                    .stroke(colour(colours.fill),
                            style: StrokeStyle(lineWidth: ringStroke, lineCap: .round))
                    // Start the arc at twelve o'clock rather than three.
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: display.state.labelGlyph)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(glyphColour)
        }
        .frame(width: ringSize, height: ringSize)
    }

    private var ringLabel: some View {
        HStack(spacing: 4) {
            ring
            if !text.isEmpty { Text(text).foregroundStyle(barForeground) }
        }
        .font(labelFont)
    }

    private var trackLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: display.state.labelGlyph).foregroundStyle(glyphColour)
            if !text.isEmpty { Text(text).foregroundStyle(barForeground) }
        }
        .font(labelFont)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(colour(colours.track))
                    if colours.dashed {
                        Capsule().strokeBorder(colour(colours.fill),
                                               style: StrokeStyle(lineWidth: 1, dash: [2.0, 2]))
                    } else {
                        // A Rectangle clipped to the capsule, not a narrowed Capsule:
                        // a short capsule reads as its own pill rather than as a fill.
                        Rectangle().fill(colour(colours.fill))
                            .frame(width: geo.size.width * fillFraction)
                    }
                }
                .clipShape(Capsule())
            }
        }
    }

    /// One font for every state, so type no longer changes size or weight as the
    /// label moves between them, and tabular digits so the width does not reflow
    /// as the countdown ticks.
    private var labelFont: Font {
        Font(NSFont.menuBarFont(ofSize: 0)).monospacedDigit()
    }

    @MainActor private func rendered() -> NSImage {
        let content = Group {
            switch geometry {
            case .ring: ringLabel
            case .track: trackLabel
            }
        }
        let renderer = ImageRenderer(content: content)
        // Render at the highest scale factor across all screens, not
        // NSScreen.main (the screen with the active window — precisely the
        // display this feature is not about). MenuBarExtra draws one image on
        // every menu bar, so rasterizing at the active display's scale would
        // upscale a 1x bitmap onto a 2x bar on mixed-DPI setups, blurring the
        // countdown on the very screen we're trying to keep legible.
        // Downsampling a high-res rep onto a 1x bar is fine; the reverse isn't.
        renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
