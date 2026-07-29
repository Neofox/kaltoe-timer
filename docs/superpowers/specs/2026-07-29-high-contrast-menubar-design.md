# High-contrast menu bar label on inactive displays

## Problem

On a multi-display setup, macOS dims the menu bar on whichever display does not
hold the active window. The 칼퇴타이머 label — a template-rendered `timer` glyph
plus the countdown text — greys out with it and becomes hard to read from the
second screen, which is exactly when a glanceable timer is most useful.

The warning and critical states are unaffected: they already render as
pre-rendered coloured capsules with `isTemplate = false`, and non-template
images keep their pixels on the inactive display. Only the normal state suffers.

## Approach

Add a setting that switches the normal-state label from a template view to a
pre-rendered **non-template** `NSImage` of the same icon and text, filled with a
solid colour matched to the menu bar appearance. Same glyphs, same metrics, no
capsule — the only change is that macOS can no longer apply its template dimming.

This mirrors CodexBar's `menuBarHighContrastOnInactiveDisplays`, which the user
already runs and confirms works well. The name describes the benefit rather than
a per-display branch: `MenuBarExtra` yields one label image that macOS draws on
every display's menu bar, and there is no API to ask which display the item is
currently being drawn on. High-contrast rendering therefore applies uniformly;
the effect is that the inactive display now matches the active one.

Warning and critical keep their existing orange/red pills unchanged.

## Components

### `KaltoeCore` — label style resolution

A pure enum with a static resolver, in a new `MenuLabelStyle.swift`:

```swift
public enum MenuLabelStyle: Equatable {
    case plain              // template icon + text, current behaviour
    case solid              // non-template icon + text, appearance-matched fill
    case pill(Urgency)      // non-template capsule, current warning/critical

    public static func resolve(urgency: Urgency, highContrast: Bool) -> MenuLabelStyle
}
```

Resolution rules, in order:

1. `urgency == .warning || urgency == .critical` → `.pill(urgency)`, regardless
   of the setting. Urgency colour outranks the contrast preference.
2. `urgency == .normal && highContrast` → `.solid`
3. otherwise → `.plain`

This keeps the branch logic in `KaltoeCore` where it is unit-testable, matching
the existing split: pure logic in Core, AppKit rendering in `FlexTimer`.

### `KaltoeCore/SettingsStore.swift` — persistence

```swift
public static var highContrastOnInactiveDisplays: Bool {
    get { defaults.bool(forKey: "highContrastOnInactiveDisplays") }
    set { defaults.set(newValue, forKey: "highContrastOnInactiveDisplays") }
}
```

`defaults.bool(forKey:)` returns `false` for an absent key, so the default is
**off** with no registration needed. Same `UserDefaults` domain
(`com.perso.flextimer`) as every other setting.

Unlike the existing read-only computed properties in this file, this one needs a
setter because the popover toggle writes it.

### `FlexTimer/MenuBarLabel.swift` — rendering

`MenuBarLabel` switches on `MenuLabelStyle.resolve(...)`:

- `.plain` — the current `HStack { Image; Text }`, untouched.
- `.pill(urgency)` — the current `PillLabelImage`, untouched apart from the
  refactor below.
- `.solid` — new `SolidLabelImage`: the same `HStack { Image; Text }` rendered
  through `ImageRenderer` with `foregroundStyle` set to a solid colour and
  `image.isTemplate = false`.

Both image-backed variants currently duplicate the `ImageRenderer` plumbing
(scale from `NSScreen.main?.backingScaleFactor`, `isTemplate = false`, `??
NSImage()` fallback). Factor that into one private helper taking the styled
content, so the two call sites differ only in styling.

**Font.** The `.solid` variant must use `Font(NSFont.menuBarFont(ofSize: 0))`,
not the pill's `.system(size: 12, weight: .medium)`. The `.plain` branch inherits
the menu bar font from its host; rendering to an image requires naming a font
explicitly, and `menuBarFont` is the one that matches. This keeps the label's
width and weight identical when the setting is toggled — a decision taken
deliberately, so there is no visible shift.

**Colour.** `@Environment(\.colorScheme)` read inside `MenuBarLabel`: `.dark`
→ white glyphs, `.light` → black. The label re-renders every second as the
countdown ticks, so an appearance change is picked up within a second without an
observer.

### `FlexTimer/MenuBarView.swift` — the toggle

A `Toggle("High contrast on other displays", isOn:)` bound to an
`AppState.highContrastOnInactiveDisplays` `@Published` property, whose setter
writes through to `SettingsStore`. Placed in the popover next to the existing
Refresh/Quit controls.

The toggle exists because an external `defaults write` is not reliably observed
by a running app — the domain is cached, so tuning the setting from a shell
would mean relaunching after each change. This is a visual preference the user
needs to flip and immediately judge on the other screen, so live toggling is the
point, not a convenience.

`AppState` already drives the label through `@Published` state, so the toggle
propagates to `MenuBarLabel` through the existing observation path.

## Data flow

```
UserDefaults ──> SettingsStore.highContrastOnInactiveDisplays
                          │
              ┌───────────┴────────────┐
              │                        │
   AppState.@Published          MenuLabelStyle.resolve(
   (popover Toggle r/w)             urgency:, highContrast:)
              │                        │
              └────────> MenuBarLabel ─┘
                              │
                    .plain / .solid / .pill
```

## Error handling

There is no failure path worth handling. `ImageRenderer.nsImage` is already
guarded with `?? NSImage()` in the existing pill code; the new variant reuses
that same helper and inherits the guard. A missing defaults key reads as
`false`, which is the intended default.

## Testing

- `MenuLabelStyleTests` (new, in `KaltoeCoreTests`) — the resolver across the
  matrix of `Urgency` × `highContrast`. Specifically pins that warning and
  critical stay `.pill` when high contrast is on, so the setting can never
  suppress an urgency colour.
- `SettingsStoreTests` (existing) — add coverage that the key defaults to
  `false` when absent and round-trips through the setter.

The rendering itself is not meaningfully unit-testable — `ImageRenderer` and
`NSScreen` are AppKit surfaces, and the property that matters (legibility on a
dimmed menu bar) is only observable by eye. It is verified manually.

## Verification

Build, install the bundle, then with a second display attached:

1. Setting off, focus a window on display A — confirm the label on display B is
   dimmed (the current, reported behaviour).
2. Toggle it on in the popover — confirm the label on display B is now legible
   and that display A is unchanged in size and position.
3. Switch between Light and Dark mode — confirm the glyphs invert correctly.
4. Let the countdown cross the 30-minute and 10-minute thresholds (or set a
   manual start time to force it) — confirm the orange and red pills still
   appear with the setting on.

## Known risk

`@Environment(\.colorScheme)` inside a `MenuBarExtra` label is assumed to
resolve against the menu bar's effective appearance. If it instead tracks the
app's appearance, the light-mode-with-dark-wallpaper case would render black
glyphs on a dark bar. Step 3 of Verification is what catches this.

The fallback, if it fails, is to read `effectiveAppearance` from the status item
button — which requires locating the `NSStatusItem` that `MenuBarExtra` creates
internally, via `NSStatusBar`/`NSApp.windows` spelunking. That is deliberately
not built up front: it is real complexity to carry, and only warranted if the
simple path is shown to be wrong.

## Out of scope

- The Linux tray / `StatusLine` output. The dimming is a macOS menu bar
  behaviour; the Linux daemon renders through a different path with no
  equivalent problem.
- Any change to the warning/critical pill appearance.
- Per-display rendering. Not achievable with `MenuBarExtra`, as described above.
