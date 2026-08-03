import Foundation

/// Menu bar label geometry — the user's choice between a closing arc and a filling
/// capsule. Both render as non-template images in every state, so neither dims on
/// the menu bar of an unfocused display; that is why the old high-contrast
/// preference no longer has anything to decide.
public enum LabelGeometry: String, CaseIterable, Sendable {
    case ring, track
}

/// An sRGB colour with alpha, as plain components.
///
/// Not `SwiftUI.Color`, deliberately: `KaltoeCore` builds for Linux, where SwiftUI
/// does not exist. `FlexTimer` maps these across the boundary.
public struct RGBA: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `RGBA(0x5aa9f8)` — the form the design spec writes its palette in, so the
    /// two can be compared by eye.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  alpha: alpha)
    }

    /// `"#5aa9f8"` — the form the daemon puts on the wire, because the Linux tray
    /// strokes its border with Cairo and cannot resolve a `LabelFill`.
    ///
    /// Alpha is dropped: nothing on that wire is translucent, and a border drawn at
    /// less than full opacity over a panel of unknown colour is not a thing the tray
    /// can reason about. Components are clamped before scaling — this is public
    /// surface, and `String(format:)` on a NaN would emit garbage into the JSON.
    public var hex: String {
        func channel(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return Int((min(1, max(0, value)) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", channel(red), channel(green), channel(blue))
    }
}

/// One colour in both menu bar appearances. A spectrum stop is not a single colour:
/// the dark-bar values need darkening to hold contrast against a light bar.
public struct ColourPair: Equatable, Sendable {
    public var light: RGBA
    public var dark: RGBA

    public init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }
}

/// A fill the view resolves. The `.system` cases exist so the label's alerting
/// colours are the *same* colours the popover already draws rather than tuned
/// near-neighbours — `KaltoeCore` cannot name SwiftUI colours, so it names the
/// intent and `MenuBarLabel` resolves it.
///
/// `.systemOrange` is literally the week strip's over-target colour
/// (`WeekBarRow.swift:80`), and both are what the shipping pill already uses
/// (`MenuBarLabel.swift:26`). `.systemRed` has nothing to match in the strip, which
/// has no limit colour at all — so the red is the label's own, taken from the system
/// only so that the two alerting colours stay consistent with each other. Copying
/// Apple's hex values here instead would reintroduce exactly the near-match that
/// this removes, and would drift silently whenever they retune them.
public enum LabelFill: Equatable, Sendable {
    case pair(ColourPair)
    case systemOrange
    case systemRed

    /// One concrete `#rrggbb` for the Linux tray's progress border.
    ///
    /// The **dark** half of a pair, unconditionally. The tray cannot ask its panel
    /// what colour it is — appindicator exposes no such thing — and the icon renderer
    /// already assumes a dark one, drawing its text at `#dfdfdf` to match the static
    /// icons. Sending the light variant to a dark panel would be the worse mistake of
    /// the two, since these are the values tuned to be legible there.
    ///
    /// The two alerting cases resolve to Apple's own systemOrange and systemRed, which
    /// are exactly `kaltoe-tray.py`'s `PILL_COLORS`. That is not a coincidence to
    /// preserve by hand: the border is suppressed under warning and critical precisely
    /// because the pill already owns those states, so if these ever diverge from the
    /// tray's constants nothing on screen can show it.
    public var wireHex: String {
        switch self {
        case .pair(let pair): return pair.dark.hex
        case .systemOrange: return RGBA(0xff9500).hex
        case .systemRed: return RGBA(0xff3b30).hex
        }
    }
}

/// What the label's colour depends on. Narrower than `DisplayState` because colour
/// does not care *which* phase of the working day you are in, only that you are in
/// one — the spectrum handles the rest from progress.
public enum LabelPhase: Equatable, Sendable {
    case idle       // no session, or no record yet — nothing to colour
    case working    // on the clock, inside the day's target
    case overtime   // on the clock, past target, within both company limits
    case atLimit    // on the clock, past target, at the weekly cap or past the cutoff
    case settled    // clocked out

    /// `clockedIn` is authoritative for `.settled`; urgency only separates
    /// `.atLimit` from `.overtime` while you are still on the clock.
    ///
    /// Deliberately not urgency-first. `hasReachedWeeklyCap` yields `.critical`
    /// on or off the clock (`DisplayState.swift:65-66`), so keying `.atLimit` off
    /// urgency alone would paint a finished day red.
    public init(_ display: MenuDisplay) {
        switch display.state {
        // Weekend joins them: nothing is running, which is exactly what `.idle` draws —
        // neutral, dashed, no fill. No new palette branch, and no new colour.
        case .noSession, .notClockedIn, .weekend:
            self = .idle
        case .toLunch, .onBreak, .counting:
            self = .working
        case .overtime(_, let clockedIn):
            guard clockedIn else { self = .settled; return }
            self = display.urgency == .critical ? .atLimit : .overtime
        }
    }
}

/// The label's colours. Pure, so the whole palette is testable without AppKit.
public enum LabelPalette {
    public struct Colours: Equatable, Sendable {
        /// The arc stroke, or the capsule's filled portion.
        public var fill: LabelFill
        /// `nil` means the glyph follows the menu bar's own foreground colour.
        public var glyphTint: LabelFill?
        /// The unfilled remainder. A `ColourPair` and not a `LabelFill`: it is a faint
        /// wash with no system counterpart to defer to.
        public var track: ColourPair
        /// Draw the track dashed — used where there is no progress to show.
        public var dashed: Bool
    }

    /// Spectrum stops, equally spaced across `progress` 0…1: blue, teal, green,
    /// amber. The light values are the same hues darkened to hold contrast on a
    /// light bar.
    ///
    /// Saturated past the original mockup's values, which read washed-out at ring
    /// size: an 18pt ring shows each hue through a 2pt stroke, far less area than
    /// the mockup's swatches, and a pale colour has little chance to register.
    /// The mid-day green was the worst of them at S=0.45. Hues are unchanged —
    /// only saturation and value moved, so the progression reads the same.
    ///
    /// Every stop clears 3:1 against both bars, the WCAG floor for a graphical
    /// element. Two got slightly worse in the trade and are the ones to watch if
    /// these are ever pushed further: dark blue 6.7→5.0, light teal 4.1→3.5.
    static let stops: [ColourPair] = [
        ColourPair(light: RGBA(0x0a64d1), dark: RGBA(0x258ef7)),
        ColourPair(light: RGBA(0x079482), dark: RGBA(0x14ccb6)),
        ColourPair(light: RGBA(0x329e18), dark: RGBA(0x51cc29)),
        ColourPair(light: RGBA(0xb87209), dark: RGBA(0xf29b0c)),
    ]

    /// The alerting colours are not constants here at all — they are `LabelFill`'s
    /// `.systemOrange`/`.systemRed`, so past target the label draws the popover's own
    /// orange rather than a tuned near-neighbour of it.
    static let neutral = ColourPair(light: RGBA(0x6c6c74), dark: RGBA(0xa0a0a8))
    static let emptyTrack = ColourPair(light: RGBA(0x000000, alpha: 0.16),
                                       dark: RGBA(0xffffff, alpha: 0.22))

    public static func resolve(progress: Double, phase: LabelPhase) -> Colours {
        switch phase {
        case .idle:
            return Colours(fill: .pair(neutral), glyphTint: nil, track: emptyTrack, dashed: true)
        case .working:
            // No glyph tint through the working day: all the colour lives in the
            // fill and the glyph stays the bar's own colour, which is what keeps
            // the label quiet on either appearance. The spec left this
            // underspecified — the mockup tinted the late-afternoon figure — and
            // this is the restrained reading of it.
            return Colours(fill: .pair(spectrum(progress)), glyphTint: nil,
                           track: emptyTrack, dashed: false)
        case .overtime:
            // Progress is ignored past target: the colour is discrete there, so a
            // ring that stopped short cannot come out a blended orange.
            return Colours(fill: .systemOrange, glyphTint: .systemOrange,
                           track: emptyTrack, dashed: false)
        case .atLimit:
            return Colours(fill: .systemRed, glyphTint: .systemRed,
                           track: emptyTrack, dashed: false)
        case .settled:
            return Colours(fill: .pair(neutral), glyphTint: nil, track: emptyTrack, dashed: false)
        }
    }

    /// Linear interpolation across `stops`.
    ///
    /// Total: `dayProgress` already guarantees `0...1`, but `resolve` is public
    /// surface and an unclamped or non-finite value would index out of bounds — and
    /// `Int(_: Double)` traps outright on `NaN`.
    ///
    /// The guard is `isNaN`, not `isFinite`, deliberately: the clamp below handles
    /// the infinities correctly on its own (`min(1, max(0, .infinity))` is 1), so
    /// only `NaN` — which fails every comparison and so survives a clamp — needs
    /// intercepting.
    static func spectrum(_ progress: Double) -> ColourPair {
        guard !progress.isNaN else { return stops[0] }
        let p = min(1, max(0, progress))
        let scaled = p * Double(stops.count - 1)
        // Clamped to the second-to-last stop so p == 1 lands on `t == 1` of the
        // final segment rather than reading one past the end.
        let i = min(stops.count - 2, Int(scaled.rounded(.down)))
        let t = scaled - Double(i)
        return ColourPair(light: lerp(stops[i].light, stops[i + 1].light, t),
                          dark: lerp(stops[i].dark, stops[i + 1].dark, t))
    }

    /// Weighted rather than the shorter `a + (b - a) * t`, which is not endpoint-exact:
    /// at `t == 1` it rounds twice and misses `b` by one ULP for one of the eighteen
    /// channel pairs — the final segment's dark blue, 0x6a→0x2a. The tests compare
    /// whole `ColourPair`s against `stops[3]` for exact equality, so `spectrum(1)`, and
    /// the clamped `2` and `.infinity` with it, could not pass. This form is exact at
    /// both `t == 0` and `t == 1` by construction.
    static func lerp(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(red: a.red * (1 - t) + b.red * t,
             green: a.green * (1 - t) + b.green * t,
             blue: a.blue * (1 - t) + b.blue * t,
             alpha: a.alpha * (1 - t) + b.alpha * t)
    }
}
