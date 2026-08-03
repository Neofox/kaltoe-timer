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
/// both. Every state takes that path, so the label holds its colour on every menu
/// bar at once and there is no rendering choice left for a preference to make.
struct MenuBarLabel: View {
    let display: MenuDisplay
    let text: String
    /// 0…1, from `WorkCalculator.dayProgress`. Already clamped and finite.
    ///
    /// Drives the **colour** only. The arc's length comes from `display.fillProgress`,
    /// which measures the current phase rather than the day.
    let progress: Double
    let geometry: LabelGeometry

    /// Resolves against the menu bar's own appearance, so every colour opposes
    /// whatever the bar is drawn in.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: rendered())
            // The rendered image has no per-element accessibility, so `text` alone
            // would leave the phase unspoken now that the glyph carries it.
            // `spokenLabel` restates it in words, and is tested in KaltoeCore.
            .accessibilityLabel(display.spokenLabel)
    }

    private var phase: LabelPhase { LabelPhase(display) }

    /// Resolved from `progress` — the whole day — while the arc's *length* comes from
    /// `display.fillProgress`, the current phase. The two are different numbers on
    /// purpose: hue answers "where am I in the day", length answers "how close is the
    /// thing I am counting down to". See `MenuDisplay.fillProgress`.
    ///
    /// They can be keyed independently because `LabelRenderCache.Key` already carries
    /// the resolved `Colours` beside `fill`, so nothing about the cache weakens by
    /// letting them diverge.
    private var colours: LabelPalette.Colours {
        LabelPalette.resolve(progress: min(1, max(0, progress)), phase: phase)
    }

    /// How much of the arc or capsule to fill: whatever `computeDisplay` decided this
    /// phase's segment has run, quantised.
    ///
    /// The phase reasoning all lives in `MenuDisplay.fillProgress` now — including the
    /// full-past-target rule and the settled day's clock-out measurement, both of which
    /// this property used to make for itself off `progress`.
    ///
    /// Clamped for the same reason `LabelPalette.spectrum` clamps its own input: the
    /// value arrives already clamped and finite today, but `.trim(to:)` and a frame
    /// width are no more forgiving than an array index. Quantised so the render cache
    /// has a stable key — the ring's circumference is about 50pt, so at 2× one step is
    /// half a pixel, invisible, while a 9h day drops from 32,400 rasterisations to at
    /// most 200.
    private static let fillSteps: Double = 200

    private var fillFraction: Double {
        let raw = min(1, max(0, display.fillProgress))
        return (raw * Self.fillSteps).rounded() / Self.fillSteps
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
        guard let tint = colours.glyphTint else { return barForeground }
        return colour(tint)
    }

    // MARK: geometry

    /// The three ring metrics live together because they must move together: the
    /// glyph has to stay inside `ringSize - 2 * ringStroke` of clear space, and
    /// bumping the diameter without the glyph leaves it rattling around.
    ///
    /// The ceiling is the menu bar's 22pt. Note the label's height is the taller of
    /// the ring and the text line, and `NSFont.menuBarFont` runs about 16pt — so at
    /// the original 14 the ring was not the height driver at all, which is why it
    /// read small beside the digits. At 18 it is, with 2pt to spare either side.
    /// That spare is the whole margin: much past 18 and the bar clips or downscales.
    ///
    /// The stroke is where all the colour is, and 2pt of it was too little to read a
    /// hue through — the spectrum's stops were already saturated once for this reason
    /// and the ring was still the weakest place to see them. 2.5 buys a quarter more
    /// coloured area at the same 18pt footprint, which the diameter cannot give:
    /// the 22pt ceiling above is a hard stop, so thickness is the only lever left.
    /// It leaves 13pt of clear space for a 9pt glyph, down from 14.
    private let ringSize: CGFloat = 18
    private let ringStroke: CGFloat = 2.5
    private let ringGlyphSize: CGFloat = 9

    private var ring: some View {
        ZStack {
            Circle()
                .inset(by: ringStroke / 2)
                // The dashed stroke takes the fill colour in both geometries, so the
                // idle state — the one every user sees every morning — draws at the
                // same weight here as in Track. `.idle` sets `fill` to the neutral
                // grey precisely to be that stroke; the faint `track` wash it used to
                // use can be all but invisible on a light bar.
                // The gap tracks `ringStroke` rather than being a constant: a round cap
                // is drawn half a line width past each end of its dash, so the ink
                // grows and the gap shrinks by the same amount the stroke thickens.
                // Left at 2.0 when the stroke went to 2.5 the dashes would have closed
                // up and the idle ring would read solid. This keeps the net gap exactly
                // what it was at 2pt.
                .stroke(colours.dashed ? colour(colours.fill) : colour(colours.track),
                        style: StrokeStyle(lineWidth: ringStroke, lineCap: .round,
                                           dash: colours.dashed ? [1.5, ringStroke] : []))
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
                .font(.system(size: ringGlyphSize, weight: .semibold))
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
        // Render at the highest scale factor across all screens, not
        // NSScreen.main (the screen with the active window — precisely the
        // display this feature is not about). MenuBarExtra draws one image on
        // every menu bar, so rasterizing at the active display's scale would
        // upscale a 1x bitmap onto a 2x bar on mixed-DPI setups, blurring the
        // countdown on the very screen we're trying to keep legible.
        // Downsampling a high-res rep onto a 1x bar is fine; the reverse isn't.
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

        // In the key so that plugging in a display re-renders at the new scale rather
        // than serving a bitmap sized for the old one.
        let key = LabelRenderCache.Key(glyph: display.state.labelGlyph, text: text,
                                       fill: fillFraction, colours: colours,
                                       geometry: geometry,
                                       dark: colorScheme == .dark, scale: scale)
        if key == LabelRenderCache.key, let cached = LabelRenderCache.image { return cached }

        let content = Group {
            switch geometry {
            case .ring: ringLabel
            case .track: trackLabel
            }
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        LabelRenderCache.key = key
        LabelRenderCache.image = image
        return image
    }
}

/// The rasterised label, memoised on everything that determines its pixels.
///
/// `body` runs about once a second because `display` carries a `timeLeft` that changes
/// on every tick — but the pixels almost never do. The text is minute-resolution and the
/// fill advances a fraction of a pixel per second, so rasterising on every pass meant
/// roughly sixty renders a minute for one or two distinct images. Measured 3% idle CPU
/// before this, against a `.plain` template path that used to rasterise nothing at all.
///
/// Main-actor isolated rather than `nonisolated(unsafe)`: `rendered()` is already
/// `@MainActor`, so the isolation is free rather than a shrug. One slot is the whole
/// cache, because there is exactly one menu bar label in the process — `MenuBarExtra`
/// draws a single image on every bar.
@MainActor private enum LabelRenderCache {
    /// Every input `rendered()` reads. Miss anything and the label goes stale; the fill
    /// and the colours both derive from the quantised `fillFraction`, so the pair cannot
    /// drift apart.
    struct Key: Equatable {
        let glyph: String
        let text: String
        let fill: Double
        let colours: LabelPalette.Colours
        let geometry: LabelGeometry
        let dark: Bool
        let scale: CGFloat
    }

    static var key: Key?
    static var image: NSImage?
}
