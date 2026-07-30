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
        case .noSession, .notClockedIn:
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
        public var fill: ColourPair
        /// `nil` means the glyph follows the menu bar's own foreground colour.
        public var glyphTint: ColourPair?
        /// The unfilled remainder.
        public var track: ColourPair
        /// Draw the track dashed — used where there is no progress to show.
        public var dashed: Bool
    }

    /// Spectrum stops, equally spaced across `progress` 0…1: blue, teal, green,
    /// amber. Dark values are the approved mockup's; the light values are the same
    /// hues darkened to hold contrast on a light bar, and are the two-known-plus-
    /// derived starting point that the hardware pass adjusts.
    static let stops: [ColourPair] = [
        ColourPair(light: RGBA(0x1f6fd0), dark: RGBA(0x5aa9f8)),
        ColourPair(light: RGBA(0x1f8578), dark: RGBA(0x3fbfb0)),
        ColourPair(light: RGBA(0x4f9e3c), dark: RGBA(0x7fc06a)),
        ColourPair(light: RGBA(0xb0741a), dark: RGBA(0xe8a02a)),
    ]

    /// Shared with the popover's week strip, which is also orange past target and
    /// red at a limit. The working day's colours are the label's alone; these two
    /// are the vocabulary the whole app speaks.
    static let overtimeColour = ColourPair(light: RGBA(0xc96a12), dark: RGBA(0xe8862a))
    static let limitColour = ColourPair(light: RGBA(0xb52a22), dark: RGBA(0xe0433a))
    static let neutral = ColourPair(light: RGBA(0x6c6c74), dark: RGBA(0xa0a0a8))
    static let emptyTrack = ColourPair(light: RGBA(0x000000, alpha: 0.16),
                                       dark: RGBA(0xffffff, alpha: 0.22))

    public static func resolve(progress: Double, phase: LabelPhase) -> Colours {
        switch phase {
        case .idle:
            return Colours(fill: neutral, glyphTint: nil, track: emptyTrack, dashed: true)
        case .working:
            // No glyph tint through the working day: all the colour lives in the
            // fill and the glyph stays the bar's own colour, which is what keeps
            // the label quiet on either appearance. The spec left this
            // underspecified — the mockup tinted the late-afternoon figure — and
            // this is the restrained reading of it.
            return Colours(fill: spectrum(progress), glyphTint: nil,
                           track: emptyTrack, dashed: false)
        case .overtime:
            // Progress is ignored past target: the colour is discrete there, so a
            // ring that stopped short cannot come out a blended orange.
            return Colours(fill: overtimeColour, glyphTint: overtimeColour,
                           track: emptyTrack, dashed: false)
        case .atLimit:
            return Colours(fill: limitColour, glyphTint: limitColour,
                           track: emptyTrack, dashed: false)
        case .settled:
            return Colours(fill: neutral, glyphTint: nil, track: emptyTrack, dashed: false)
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

    /// Weighted rather than the shorter `a + (b - a) * t`, because the endpoints have
    /// to come out *exactly* equal to the stops and that form does not: at `t == 1`,
    /// `a + (b - a)` rounds twice and lands one ULP off `b` for most channel pairs
    /// (0x6a→0x2a is one). `progress == 1` is a real value — it is the whole
    /// afternoon's destination — so the final stop being unreachable is not academic.
    /// This form is exact at `t == 0` and `t == 1` by construction.
    static func lerp(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(red: a.red * (1 - t) + b.red * t,
             green: a.green * (1 - t) + b.green * t,
             blue: a.blue * (1 - t) + b.blue * t,
             alpha: a.alpha * (1 - t) + b.alpha * t)
    }
}
