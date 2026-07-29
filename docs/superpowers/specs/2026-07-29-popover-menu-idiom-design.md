# Popover: menu idiom, and re-syncing on unlock

## Problem

Two complaints, one of which turned out to have a different cause than it looked.

**The popover's controls look wrong.** `MenuBarView` renders its buttons inside
a `.leading` `VStack`, so "↻ Refresh from Flex" and "Quit" take their intrinsic
widths and leave a ragged right edge. The `↻` is a text glyph rather than an SF
Symbol, inconsistent with the `timer`/`fork.knife` symbols the menu bar itself
uses. The high-contrast checkbox sits between two verbs — Refresh, toggle, Quit
— with no separator, mixing a preference into a list of commands, and its label
is close enough to the content width to wrap.

**Every morning starts with a click on Refresh.** The user clocks in at Flex,
unlocks their Mac seconds later, and the app still shows no record for today —
so they click Refresh. The app polls every 10 minutes, and its only lifecycle
hook is `NSWorkspace.didWakeNotification` (`AppState.swift:63`), which fires
when the Mac wakes **from sleep**. A Mac that was merely locked — screen lock,
Touch ID, hot corner, lid never closed — never posts it. Even when it does
fire, waking can outrun Flex's API reflecting a clock-in made moments earlier.

The first is presentation; the second is lifecycle. They are addressed together
because they share one motivation — the morning friction — and because the
popover's layout changes depending on whether a record exists, which is exactly
what the lifecycle fix makes rare.

## Approach

Restyle the popover into two visually distinct zones so it reads as a menu
rather than a settings form, move the primary action to where it is needed when
there is no record, and re-sync on unlock so that state stops being the common
one.

### Zones

- **Information zone** — inset text rows (`Back at`, `Started`, `Leave at`,
  `Time left`, `Week OT`, sync and error captions, and the manual-entry field).
  Never interactive, never highlights.
- **Action zone** — full-bleed rows that highlight under the cursor, separated
  by dividers.

The outer `VStack` drops to `spacing: 0`, and each zone owns its horizontal
padding. This is forced, not stylistic: a menu-style highlight runs edge to edge
while its text stays inset, so a single shared padding cannot serve both.

### The primary action moves

Exactly one action is primary, and where it renders depends on state:

| State                    | Primary action   | Renders                                 |
| ------------------------ | ---------------- | --------------------------------------- |
| No Flex session          | Sign in to Flex… | directly under the status message       |
| Session, no record today | Flex re-sync     | directly under the status message       |
| Session with a record    | Flex re-sync     | in the action zone, above High contrast |

Only one instance is ever built. When the primary action has moved up, the
action zone holds just High contrast and Quit.

This is the reorder the user asked for: when there is no active day, Refresh is
the thing you want, and the manual-entry form — a fallback for when Flex is
unreachable — should not sit above it.

## Components

### `Sources/FlexTimer/MenuRow.swift` — new

The row primitives, in their own file so `MenuBarView` stays composition rather
than composition plus control implementation.

```swift
/// A full-bleed menu-style row: icon column, title, optional trailing
/// accessory, solid accent highlight on hover. Horizontal padding lives here
/// rather than on the parent stack, because the highlight must reach the
/// popover's edges while the text stays inset.
struct MenuRow<Trailing: View>: View {
    let icon: String
    let title: String
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false
}
```

Two call shapes: a command row where `Trailing` is `EmptyView`, and a
preference row whose trailing view is
`Toggle("", isOn:).labelsHidden().toggleStyle(.switch).controlSize(.mini)` —
`labelsHidden()` matters, or SwiftUI reserves space for the empty label and
the switch drifts left of the popover's edge. The whole row is the hit target — `.contentShape(Rectangle())` plus a tap
gesture — so clicking the label toggles the switch, not just the switch itself.

**Highlight:** solid `Color.accentColor` fill with the title and icon knocked
out to white, matching a real `NSMenu`. This is the assertive choice; the
softer alternative is `Color.accentColor.opacity(0.15)` with unchanged
foreground, and it is a one-line change if the solid fill reads as too heavy in
practice.

Icons, all SF Symbols: `arrow.clockwise` (Flex re-sync), `person.crop.circle`
(Sign in), `circle.lefthalf.filled` (Stay readable when unfocused), `power`
(Quit).

### `Sources/FlexTimer/MenuBarView.swift` — restructured

Composes the two zones and decides where the primary action goes. Copy changes:

- "↻ Refresh from Flex" → **"Flex re-sync"**
- "High contrast on other displays" → **"Stay readable when unfocused"**, with
  a `.help()` tooltip carrying the full explanation: "Renders the icon and time
  at full contrast so they stay legible on the menu bar of a display that
  doesn't have focus."

**Width goes 240 → 280.** This follows from the label, not from taste: "Stay
readable when unfocused" is 28 characters ≈ 179pt at the 13pt system font, and
at 280pt the row leaves 192pt for the title after 24pt of padding, a 24pt icon
column, and a 40pt trailing switch. At 260pt it would have been 172pt and the
label would clip or wrap.

The manual-entry row keeps its `DatePicker` — an inline date field is a form
control and dressing it as a menu row would be worse — but gains a `Started at`
label and `.controlSize(.small)` on both the field and a `.bordered` Set button,
so their heights match, which they currently do not. It is introduced by an
"Or set it manually" caption that marks it as the fallback it is.

`syncError` gains an `exclamationmark.triangle` symbol so it reads as a warning
rather than as orange text.

### `Sources/FlexTimer/AppState.swift` — re-sync on unlock

A second observer alongside the existing wake observer:

```swift
private var unlockObserver: NSObjectProtocol?

unlockObserver = DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.apple.screenIsUnlocked"),
    object: nil, queue: .main
) { [weak self] _ in
    Task { @MainActor in await self?.resyncAfterUnlock() }
}
```

`com.apple.screenIsUnlocked` is a distributed notification, not an
`NSWorkspace` one, and it fires on unlock whether or not the Mac slept — which
is the case `didWakeNotification` misses. The wake observer stays: waking and
unlocking are different events and both deserve a re-sync.

`resyncAfterUnlock` retries, because the user clocks in seconds before
unlocking and Flex may not have caught up:

```swift
/// Re-sync on unlock, retrying briefly when Flex has no record yet — the user
/// typically clocks in moments before unlocking, and the API lags that.
func resyncAfterUnlock(maxAttempts: Int = 3, delay: TimeInterval = 20) async
```

It calls `refresh()`, then consults a pure policy helper to decide whether to
wait and go again.

### Retry policy — the testable seam

```swift
/// Whether an unlock re-sync should try again. Stops as soon as a record
/// arrives, stops immediately when signed out (retrying a dead session just
/// hammers it), and stops at the attempt ceiling.
static func shouldRetryUnlockResync(attempt: Int, maxAttempts: Int,
                                    hasSession: Bool, hasTodayRecord: Bool) -> Bool
```

The loop mechanics around it are trivial and integration-shaped; this predicate
is where the actual policy lives, and it is unit-testable without a network or
a clock.

## Data flow

```
screen unlock ──> DistributedNotificationCenter
                        │
                  resyncAfterUnlock()
                        │
                    refresh() ──> FlexClient ──> week / today
                        │
          shouldRetryUnlockResync(...) ──no──> done
                        │yes
                   sleep(delay) ──┘

state.today == nil ──> MenuBarView renders the primary action
                       under the status message instead of
                       in the action zone
```

## Error handling

No new failure paths. `refresh()` already swallows and reports its own errors
via `syncError` and `hasSession`; `resyncAfterUnlock` adds only iteration on
top. `DistributedNotificationCenter` delivery is best-effort — a missed unlock
notification degrades to the existing 10-minute poll, which is the behaviour
today.

The new observer token is stored and never removed, matching `wakeObserver`
(`AppState.swift:38`), which is also stored and never removed. There is no
`deinit` on `AppState` and this design does not add one: the object lives for
the process lifetime, so removal would never run. Deliberate consistency, not
an oversight to copy.

## Testing

**`shouldRetryUnlockResync`** — the one piece with real logic, tested across
its matrix in `Tests/FlexTimerTests/AppStateTests.swift`: stops when a record
arrives, stops when signed out even on the first attempt, stops at the
ceiling, continues when there is a session and still no record below the
ceiling.

**`MenuRow` and `MenuBarView`** — no tests. They are pure presentation with no
extractable logic, and the properties that matter (does the highlight look
right, does the label fit) are only observable by eye. This is the same
judgement made for `MenuBarLabel`, and it is verified the same way.

The suite must stay green at its current 131 plus the new policy tests.

## Verification

By eye, after `./scripts/bundle.sh`:

1. Hovering Flex re-sync, the toggle row, and Quit each highlights edge to edge
   in the accent colour with white text; the information rows above never do.
2. "Stay readable when unfocused" fits on one line beside its icon and switch.
3. Clicking anywhere on the toggle row flips the switch.
4. With no record for today, Flex re-sync appears above the manual-entry field,
   and the action zone holds only the toggle and Quit.
5. Lock the screen without letting the Mac sleep, clock in via the Flex web UI,
   unlock — the record appears without touching Refresh. This is the one that
   proves the actual fix.

## Out of scope

- Changing the 10-minute poll interval.
- Dismissing the popover after an action. `MenuBarExtra` offers no clean
  programmatic dismissal without switching to the `isPresented:` initialiser,
  which is a larger change than this warrants.
- The `Week OT`, `Time left`, and other information rows' content or formatting
  — only their insets move, to line up with the full-bleed rows below.
- Any change to what the menu bar label itself renders.
