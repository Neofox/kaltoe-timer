# Menu bar label overhaul — expressive glyphs, a day-long colour spectrum, and two geometries

## Problem

The popover was just overhauled (week strip, per-day tracks, reduced-target caption). The
menu bar label it hangs off did not move with it, and it is the part the user actually
looks at all day.

Concretely, as of `3b1f393`:

- **One glyph does four jobs.** `DisplayState.iconName` returns `timer` for `.noSession`,
  `.notClockedIn`, `.counting` and `.overtime` alike. The state is only readable from the text.
- **The text does the glyph's job.** `BREAK ` and `OT ` prefixes are words carrying
  information a symbol could carry, and `—` / `--:--` read as placeholders rather than states.
- **Colour is two alarm buckets.** Flat `.orange` at ≤30 min, flat `.red` at ≤10 min or at a
  limit, nothing otherwise. The label says nothing about where you are in the day until it
  starts shouting.
- **Nothing is alive.** The popover's week strip moves; the label is a static number.

The user's framing, verbatim: the label should be "a bit more fun, a bit less simple", with
the personality living in the glyph, in motion, and in colour — explicitly _not_ in playful
copy, which stays a clean countdown.

Not in scope, and deliberately: label width jitter and the three-fonts-across-three-styles
inconsistency. Both are real (nothing in the label uses `monospacedDigit()`; the pill is
`.system(size: 12, weight: .medium)`, the solid render is `NSFont.menuBarFont`, plain
inherits SwiftUI's default), and both are fixed incidentally by the single render path below.
They are not the motivation.

## Approach

Three changes that compose into one system:

1. **A per-phase glyph set** — eight symbols instead of three, so the icon carries the state.
2. **A day-long colour spectrum** — colour interpolates blue → teal → green → amber as the
   day runs down, then goes orange in overtime and red at a limit.
3. **Two geometries, one spectrum** — a progress **Ring** around the glyph, or a filling
   **Track** capsule behind the whole label. A two-segment picker in the popover chooses;
   the palette is identical either way, so the preference is purely about shape.

The fill — arc sweep or capsule width — always means the same thing: progress toward
today's leave time. It never changes meaning and never runs backwards, even though the
number beside it changes meaning between phases.

### Why the spectrum, given the popover speaks accent-then-orange

The week strip uses accent up to target and orange past it. A continuous spectrum invents
colours the popover has no counterpart for — a green label at 15:00 corresponds to nothing
in the strip. This was put to the user as an explicit trade against a third option that
reused the app's existing vocabulary, and the spectrum was chosen for being the more fun of
the two. The incoherence is accepted, and bounded: **the over-target orange is shared, and
literally so.** Past target the label fills with the system orange, which is the same colour
`WeekBarRow.swift:70` already fills its over-target segment with — not a tuned
near-neighbour that would read as a second orange. Only the working day, where the strip has
nothing to say about _time of day_, carries colours of its own.

Two corrections to an earlier draft of this passage, both found during implementation:

- It claimed "once you hit a limit both are red". **The week strip has no red at all** — its
  only colours are accent, secondary and orange (`WeekBarRow.swift:25`, `:57`, `:63`, `:67`,
  `:70`, `:81`), and the weekly cap appears there as text (`Week OT 5:00 / 12:00`), not as a
  colour. The limit red is therefore the label's alone, with nothing to match.
- It specified tuned hexes for both alerting colours (`#e8862a`, `#e0433a`). Those would have
  shipped a near-match beside the strip's system orange, which is the exact defect the
  shared-colour argument exists to prevent. Both are now the system colours, which is also
  what the pill being replaced already used (`MenuBarLabel.swift:26`).

## The wire is not touched

This is the load-bearing constraint, and it inverts the obvious implementation.

`DisplayState.menuBarText` and `DisplayState.iconName` are not Mac properties. They are the
daemon's NDJSON contract (`StatusLine.init`, `StatusLine.swift:89-90`), consumed by
`linux/kaltoe-tray.py`. Three specific dependencies:

- `ICON_BASE` (`kaltoe-tray.py:68`) maps exactly `timer`, `fork.knife` and `cup.and.saucer`
  to PNG icon families, with everything else falling back to `kaltoe-timer` via `.get`.
  Adding `zzz` or `figure.walk` to `iconName` would silently flatten the lunch phases to a
  generic timer on Linux — a regression that degrades quietly rather than failing.
- `LABEL_GUIDE = "OT +88:88"` (`:69`) reserves tray width from the `OT ` prefix.
- `render_text_icon` stacks the label at the **first space** —
  `text.replace(" ", "\n", 1)` (`:85`). On KDE the tray is _only_ this text, with no glyph
  at all, so `BREAK`/`OT` are the sole phase signal there. Dropping them would make a break's
  `0:45` indistinguishable from a countdown's `0:45`, and would collapse the two-line
  stacking that the auto-fit sizing assumes.

The prefixes and the three-symbol vocabulary are load-bearing **on Linux**, precisely
because Linux has no expressive glyph to lean on. The Mac label is getting one.

Therefore: **two new Mac-only computed properties on `DisplayState`, and the wire properties
stay byte-identical.**

|       | Mac label                                      | Wire / Linux tray                                               |
| ----- | ---------------------------------------------- | --------------------------------------------------------------- |
| text  | `labelText` — `2:34`, `0:45`, `+1:00`, `자유!` | `menuBarText` — unchanged: `BREAK 0:45`, `OT +1:00`             |
| glyph | `labelGlyph` — the eight-symbol set            | `iconName` — unchanged: `timer`, `fork.knife`, `cup.and.saucer` |

Zero change to `KaltoeDaemon`, `StatusLine`, or `kaltoe-tray.py`. The cost is two parallel
mappings that could drift; the mitigation is that both live in `DisplayState.swift` and both
are covered by tests that walk the same list of states, the way `WeekSummary` and
`StatusLine.DayLine` already pair up.

## Components

### `KaltoeCore/DisplayState.swift` — the state → appearance mapping

`.overtime` gains a `clockedIn` bit:

```swift
case overtime(today: TimeInterval, clockedIn: Bool)
```

`computeDisplay` already derives `clockedIn` for its urgency branch (`DisplayState.swift:63`)
and currently discards it. The settled-day appearance needs it: a day you have clocked out
of should read as done, not as still accruing. `StatusLine` ignores the new associated value,
so the wire is unaffected.

Two new properties. `labelGlyph`:

| State                            | Glyph                   | Note                       |
| -------------------------------- | ----------------------- | -------------------------- |
| `.noSession`                     | `zzz`                   | replaces the bare `—`      |
| `.notClockedIn`                  | `timer`                 | with an empty, dashed fill |
| `.toLunch`                       | `fork.knife`            | unchanged from `iconName`  |
| `.onBreak`                       | `cup.and.saucer`        | unchanged from `iconName`  |
| `.counting`, > 30 min left       | `timer`                 |                            |
| `.counting`, ≤ 30 min left       | `figure.walk`           | you are nearly free        |
| `.overtime`, clocked in, < 1 min | `figure.walk.departure` | the 자유! moment, below    |
| `.overtime`, clocked in          | `flame`                 |                            |
| `.overtime`, clocked out         | `checkmark`             | day settled                |

The `.counting` split keys off `timeLeft` directly, not off `Urgency` — see the palette
section for why `Urgency` stops driving appearance.

`checkmark` means _settled_, not _target met_. Clocking out short of target still lands in
`.overtime` with a negative `today` (`computeDisplay` falls through to it whenever
`clockOut != nil`, `DisplayState.swift:44`), so a short day gets the check too — beside a
`-0:20` and a grey ring that visibly did not fill. The check marks the day as closed; the
fill and the sign carry whether it was enough.

**One deliberate reduction from the mockups.** They showed a `sunrise` glyph at 09:00 and
`fork.knife` at 11:20, implying a morning sub-phase. No such state exists: `.toLunch` spans
clock-in to `lunch.leaveAt` as a single case (`DisplayState.swift:48-51`), so the whole
morning is one state. Splitting it would add a case to the model for decoration only. The
morning is `fork.knife` throughout, which is at least honest about what the number counts.
Recorded as a follow-up rather than smuggled in.

`labelText` — same as `menuBarText` minus the word prefixes, plus the celebration:

| State                            | `labelText` | vs `menuBarText` |
| -------------------------------- | ----------- | ---------------- |
| `.noSession`                     | `""`        | `—`              |
| `.notClockedIn`                  | `--:--`     | same             |
| `.toLunch`                       | `1:20`      | same             |
| `.onBreak`                       | `0:45`      | `BREAK 0:45`     |
| `.counting`                      | `2:34`      | same             |
| `.overtime`, clocked in, < 1 min | `자유!`     | `OT +0:00`       |
| `.overtime`                      | `+1:00`     | `OT +1:00`       |

`.noSession` renders as glyph only, with no text at all. The accessibility label must still
say "Signed out" — an empty `Text` would otherwise leave VoiceOver reading a nameless image.

### `KaltoeCore/WorkCalculator.swift` — `dayProgress`

```swift
static func dayProgress(clockIn: Date, now: Date, rules: WorkRules,
                        timeOff: TimeInterval) -> Double
```

Defined as `elapsed / span`, clamped to `0...1`, where `span` is the **whole clock-in to
leave-time interval** and `elapsed` is `now - clockIn`.

The denominator is `leaveTime(clockIn:rules:timeOff:) - clockIn`, i.e. `target + break`, not
`target`. Dividing by `target` alone would reach 1.0 a full hour before you may leave, because
`leaveTime` is `clockIn + target + breakDuration(target:)`
(`WorkCalculator.swift:30-33`). Deriving `span` from `leaveTime` rather than re-adding the
two components also means `breakDuration`'s half-day rule — no lunch once the target falls to
`dailyWork / 2` or below (`:41-43`) — is inherited rather than duplicated, so a 4h time-off day
scales to its real 4h span instead of a phantom 5h one.

This measures **distance to leave time, not work completed**, and progress therefore keeps
advancing through the lunch break instead of stalling for an hour. That is the right meaning
for a label about whether you can go home, and it is what makes the fill monotonic: the number
beside it switches from counting-to-lunch to counting-to-leave, and the fill does not flinch.

**Total by construction**, on the precedent of `StatusLine.secondsFlooredToMinute`. `target`
derives from `rules.dailyWorkHours`, a raw `Double` read from `UserDefaults` that the README
documents a `defaults write` for, so a typo can reach here. Two distinct hazards, both
guarded by returning `0`:

- `span <= 0` — reachable with `dailyWorkHours 0`, or time off at or above the target, since
  `dailyTarget` floors at zero (`:118`) and `breakDuration` then yields no lunch either.
  Division would give `±inf` or `NaN`.
- `span` or `elapsed` non-finite — `dailyWorkHours -float inf` propagates through
  `addingTimeInterval` into `span`, and `inf / inf` is `NaN`. Note `dailyTarget` already
  absorbs a `NaN` target to `0` via `max(0, NaN)`, so `NaN` arrives here as the `span <= 0`
  case rather than as a `NaN`; the finiteness guard is for the infinities.

A clamped `Double` in `0...1` is the only thing the renderer ever sees.

### `KaltoeCore/LabelAppearance.swift` — new file

Geometry, persisted, defaulting to `.ring`:

```swift
public enum LabelGeometry: String, CaseIterable, Sendable { case ring, track }
```

The label's own view of the world, narrower than `DisplayState` because colour does not care
which phase of the working day you are in — only whether you are in one:

```swift
public enum LabelPhase: Equatable, Sendable {
    case idle           // .noSession, .notClockedIn — nothing to colour
    case working        // .toLunch, .onBreak, .counting — spectrum applies
    case overtime       // clocked in, past target, within both limits
    case atLimit        // clocked in, past target, weekly cap reached or past the cutoff
    case settled        // clocked out
}
```

`.overtime` versus `.atLimit` is the distinction `computeDisplay` already draws via
`WorkCalculator.hasReachedWeeklyCap` and `WorkCalculator.isPastOvertimeCutoff`
(`DisplayState.swift:65-69`). `LabelPhase` is derived from `MenuDisplay`, so those predicates
are not re-evaluated and cannot disagree with the urgency they already drive.

And the palette, pure:

```swift
public enum LabelPalette {
    public struct Colours: Equatable, Sendable {
        public var fill: ColourPair        // arc stroke, or capsule fill
        public var glyphTint: ColourPair?  // nil = follow the bar's own colour
        public var track: ColourPair       // the unfilled remainder
        public var dashed: Bool            // Ring's stroke, or Track's outline
    }
    public static func resolve(progress: Double, phase: LabelPhase) -> Colours
}
```

`ColourPair` carries a light and a dark value, because a spectrum stop is not one colour: the
mockup's dark-bar green `#7fc06a` needed `#4f9e3c` to read on a light bar. `MenuBarLabel`
already resolves `\.colorScheme` for exactly this reason.

Resolution:

- **`.working`** — interpolate `progress` across four stops, equally spaced at 0, ⅓, ⅔ and 1:
  blue `#5aa9f8` → teal `#3fbfb0` → green `#7fc06a` → amber `#e8a02a`.
- **`.overtime`** — the **system** orange. Discrete, not interpolated.
- **`.atLimit`** — the **system** red.
- **`.settled`** — neutral grey, filled to whatever `progress` actually reached. Not forced
  full: clocking out short of target leaves a partly-filled grey ring, which is true.
- **`.idle`** — neutral grey, empty, `dashed`.

Those four spectrum hexes are the dark-appearance values, taken from the approved mockup. The
light counterparts are the same hues darkened until they hold contrast against a light bar —
one is already known (`#4f9e3c` green) and the remainder are settled on hardware alongside the
other visual confirmations below, not guessed here.

The alerting colours take no hexes at all, and that is deliberate: hard-coding Apple's current
system-orange values would be a copy that silently drifts if Apple retunes them, reintroducing
the second-orange problem. `KaltoeCore` cannot name a SwiftUI colour (it compiles for Linux),
so `LabelFill` names the _intent_ — `.systemOrange`, `.systemRed` — and `MenuBarLabel` resolves
it to the same `Color.orange` / `Color.red` the popover uses. Parity is then true by
construction rather than by matching numbers.

**`Urgency` stops driving colour.** Today `.warning` fires at ≤30 min before leave; under the
spectrum that moment is amber _because of where it sits in the day_, not because a threshold
tripped, so keying colour off `Urgency` would double-encode it and fight the interpolation.
`Urgency` keeps its notification job — `LimitNotifier` and `SessionNotifier` are untouched —
and `LabelPhase` above is the label's own, narrower input.

`MenuLabelStyle.swift` and its three tests are **deleted**. `.plain` / `.solid` / `.pill` are
all superseded: every state is now non-template, so the branch has nothing left to decide.

### `KaltoeCore/SettingsStore.swift` — one setting swapped for one

`labelGeometry: LabelGeometry` replaces `highContrastOnInactiveDisplays`, read/write against
the same `com.perso.flextimer` domain. Default `.ring`.

The high-contrast setting is retired **because its benefit becomes unconditional** — it
existed only to stop macOS dimming a template label on an unfocused display, and Ring and
Track are both non-template in every state. The stale `UserDefaults` key is simply left
unread; no migration.

This also retires the escape hatch: there is no longer any way to get a monochrome,
menu-bar-following label. That was put to the user as an explicit third segment and declined
in favour of the simpler two.

### `FlexTimer/MenuBarLabel.swift` — rewritten, one render path

Every state becomes one pre-rendered non-template `NSImage`. That collapses the current
three-way branch and, incidentally, fixes both out-of-scope defects: one font
(`NSFont.menuBarFont(ofSize: 0)` with `.monospacedDigit()`), one glyph box, one padding, so
type no longer changes size between states and digits no longer reflow as they tick.

- **Ring** — `Circle().trim(from: 0, to: progress)`, stroked with a round cap, rotated −90°
  so it starts at twelve o'clock, glyph inset inside. Empty states draw the track dashed.
- **Track** — a `Capsule` with a clipped fill rect behind glyph and text.

The existing `ImageRenderer` scale logic is retained verbatim — rasterising at the maximum
backing scale across all screens rather than `NSScreen.main`'s. That comment
(`MenuBarLabel.swift:73-80`) is load-bearing on mixed-DPI setups and this rewrite must not
quietly drop it.

**Track's text colour stays the bar's own** rather than flipping to white where the fill
slides under it. Flipping mid-label is the fiddly part, and the one mockup cell that looked
wrong was light-bar-near-칼퇴 with an opaque orange fill.

An earlier draft of this paragraph added "with fill opacity capped on a light appearance". No
such capping was implemented, and the claim is removed rather than retrofitted: the filled
`Rectangle` draws the palette colour at full alpha, and only the **unfilled** remainder
(`emptyTrack`) is translucent, at 0.16 light / 0.22 dark. So the light-bar legibility risk is
**unmitigated by design** — dark text over a full-strength orange fill is exactly the cell the
mockup flagged. This is the weakest claim in the spec and the hardware pass is what decides
whether capping is needed at all; capping blind risks a fill too faint to read as progress.
Same precedent as the high-contrast spec's "pending visual confirmation on hardware".

### `FlexTimer/LabelGeometryRow.swift` — new file

A two-segment `Picker` (`Ring` | `Track`), replacing `highContrastRow` in `MenuBarView`.
Its own file so `MenuBarView` (186 lines, five sections already) does not grow.

`AppState` gains a published `labelGeometry` mirroring the store and writing through on set,
exactly as `highContrastOnInactiveDisplays` does today (`AppState.swift:26-28`) — so the
label re-renders immediately on change.

Needs an accessibility label naming the setting; the segments alone read as two bare words.

## 자유!

At the moment today's overtime is under one minute and you are still clocked in, the label
reads `figure.walk.departure` + `자유!`.

**One minute, chosen because it costs nothing.** `Formatting.signedHM` floors to whole
minutes, so that is exactly the span during which the overtime label would read `+0:00` — the
one minute of overtime carrying no information. 자유! does not displace a reading; it fills a
gap.

**It is therefore not a state, an animation, or a timer.** It is what `labelText` returns
while `today < 60`, derived from the same input as everything else on the label. No
dismissal timer, no latch, no `celebrating` flag, nothing that can get stuck on. Three
classes of bug are avoided by construction rather than guarded against:

- It cannot fire repeatedly, though `recompute` runs every second, because it is not an event.
- It cannot fire retroactively on launch or wake at 20:00, because by then `today ≥ 60`.
- It cannot survive a clock-out, because `labelGlyph` and `labelText` both require
  `clockedIn`.

One re-entry path does survive, and is accepted rather than guarded: a Flex re-sync that
moves today's `clockIn` later can drop `today` back under 60s and show 자유! a second time.
Adding a once-per-day latch to prevent that would cost the "not a state" property that makes
everything above true, and a second 자유! after a corrected clock-in is arguably the honest
reading anyway — the first one was based on a wrong time.

It fires whenever the day's target is met, so a 6h family day celebrates at 6h. Clock out
short of target and you never cross, so nothing happens.

No notification and no off-switch. Both were considered; a daily banner is the kind of thing
people disable within a week, and one minute a day does not need a preference until it
demonstrably grates.

## No animation in v1

The user asked for motion and this is a partial no, stated as such.

The label is a rasterised `NSImage`, so real animation means a timer driving `ImageRenderer`
on the main actor — an all-day battery cost for a fraction of a second of delight two or
three times. The advancing arc and the ramping colour already re-render every minute, which
is the movement that will actually be noticed, and 자유! provides the one moment of
punctuation.

A one-shot pulse on crossing into overtime is a clean follow-up once the static version is on
real hardware and can be judged for whether anything is missing.

## Testing

Everything load-bearing is pure and lives in `KaltoeCore`. There is no `DisplayStateTests`
today, so the first four items below land in a new one; the wire guard belongs in the existing
`StatusLineTests`.

- `labelGlyph` and `labelText` across every `DisplayState` case, including both `.overtime`
  arms and both sides of the 30-minute `.counting` split.
- `labelText` for `.overtime` at `today` = 0, 59 and 60 seconds — the 자유! boundary.
- `menuBarText` and `iconName` **unchanged** for every state. This is the Linux regression
  guard and the reason the parallel mappings are safe; it belongs in
  `StatusLineTests` alongside the existing wire assertions.

Adding `clockedIn` to `.overtime` is a source-breaking change to a public enum, so every
existing construction and pattern-match updates with it. `MenuLabelStyleTests` is deleted
outright; the rest is mechanical, and the compiler finds all of it.

- `LabelPalette.resolve` at each spectrum stop boundary, and either side of the
  working-day → overtime edge.
- `dayProgress` clamping: past leave time, before clock-in, and with a zero, negative or
  non-finite `dailyWorkHours`.
- `LabelGeometry` persistence round-trip, and the absent-key default.

Ring-versus-Track pixels get eyes on real hardware, not assertions. Specifically to confirm:
Track's text legibility over an opaque fill on a light bar, and that neither geometry clashes
with macOS 26's tinted menu bar.

## Follow-ups

1. A morning sub-phase, so the countdown to lunch can open on `sunrise` before becoming
   `fork.knife` — needs a new `DisplayState` case, deferred as decoration.
2. A one-shot pulse animation on the overtime crossing, if the static label feels inert.
3. Linux parity for the expressive glyph set — new PNG families plus `ICON_BASE` entries,
   and a `LABEL_GUIDE` narrowed once prefixes could be dropped there too. Only worth it if a
   Linux user asks; the current design leaves that tray exactly as it is.
