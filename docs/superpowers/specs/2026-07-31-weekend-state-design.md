# 주말! — a weekend state, replacing weekend correctness

## Problem

Weekends are half-modelled, and the half that exists is wrong.

`FlexRecordParser` gates `dayOffDates` and `timeOff` to weekdays (`:106`, `:110`, `:117`)
but **not work records** (`:155`), so a Saturday clock-in yields a real record.
`WorkCalculator.dailyTarget` has no weekend awareness — every day's target is `dailyWork` —
so a Saturday behaves like a Tuesday: a countdown to `clockIn + 8h + 1h`, a `Leave at` row,
and overtime past the eighth hour.

Two consequences, both live today:

- **A 9h Saturday adds `+1:00` to `Week OT` with no row on screen explaining it.** The week
  strip is Mon–Fri by design (`WeekSummary.swift:107-111`), so the total and the rows
  visibly fail to add up. Recorded as follow-ups 23 and 33; the strip is precisely what
  makes people start trusting the rows to sum.
- **The countdown is meaningless on a weekend.** Nobody works to a 칼퇴 target on a Saturday,
  so a countdown to a notional 18:00 leave time is noise dressed as information.

The obvious fix — make weekends correct: weekend target 0, weekend rows in the strip — is
the expensive one. It changes the label, the weekly total and the cap notifications for all
four users, and it buys behaviour nobody exercises.

## Approach

Declare weekends out of scope, visibly, with one state. The user's framing: _"no one will
ever work 8h+ a weekend day"_ — so hide the logic behind a `주말!` label rather than teach it
about Saturdays.

**This is a subtraction, not a feature.** It is cheaper than the correctness work _and_ it
deletes explanation the correctness gap currently requires.

### Why excluding weekend overtime is free

`weeklyOvertime` sums `max(0, dailyOvertime)` per record, and `dailyOvertime` for a completed
day is `net − target`. A weekend day under 8h therefore already contributes **zero**. Zeroing
weekend overtime outright changes the total only in the case the premise says never happens —
while deleting the case where the total and the rows disagree.

## Components

### `KaltoeCore/WorkCalculator.swift` — one predicate, hoisted not invented

```swift
public static func isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool
```

`FlexRecordParser.swift:106` already computes this inline as
`(2...6).contains(Calendar.current.component(.weekday, from: $0))`, negated. That call site
changes to use the new function, so the weekday convention lives in one tested place instead
of one literal and one duplicate. It takes a `calendar` because every other date predicate in
this file does (`isFamilyDay`, `isPastOvertimeCutoff`).

### `KaltoeCore/DisplayState.swift` — one new case, checked early

```swift
case weekend
```

In `computeDisplay`, between the session guard and the record lookup:

```swift
guard hasSession else { return MenuDisplay(state: .noSession, urgency: .normal) }
if WorkCalculator.isWeekend(now, calendar: calendar) {
    return MenuDisplay(state: .weekend, urgency: .normal)
}
guard let today else { … }
```

**Ordering is the design.** Signed-out outranks weekend because "sign in" is actionable and
`주말!` is not. Weekend outranks everything below it, including a live record — which is what
makes this one branch rather than a weekend variant of every phase. Urgency is always
`.normal`: there is nothing to warn about.

Keyed on `now`, not on any record's date. The state is a fact about today.

### Appearance

|                      | Value                                                  |
| -------------------- | ------------------------------------------------------ |
| `labelGlyph`         | `beach.umbrella`                                       |
| `labelText`          | `주말!`                                                |
| `spokenLabel`        | `"Weekend"` — English, like its siblings               |
| `menuBarText` (wire) | `주말!`                                                |
| `iconName` (wire)    | `beach.umbrella`                                       |
| `LabelPhase`         | `.idle` — reuses the existing neutral, no-fill styling |

`LabelPhase` mapping to `.idle` is the simplification: no new palette branch, no new colour,
and "nothing is running" is true.

The fill is empty because `.idle` sets `dashed: true`, and **both geometries skip the fill
entirely when dashed** (`MenuBarLabel.swift`, the `if !colours.dashed` arc guard and Track's
`if colours.dashed` branch) — not because progress happens to be zero. That distinction
matters here: on a Saturday with a Flex record, `AppState.labelProgress` is a real non-zero
number, and it is simply never drawn. Leaving it computed is deliberate; adding a second gate
for a value nothing reads would be the kind of weekend-awareness this design declines.

### The wire gains a case, and that is additive

`computeDisplay` is pure and shared with `KaltoeDaemon`, so the daemon computes `.weekend`
too and the Linux tray shows it. That is deliberate — the alternative is the same function
returning different states per platform, which is worse than the change.

It is additive rather than breaking: no existing state's `menuBarText` or `iconName` output
changes. Two specifics checked against `linux/kaltoe-tray.py`:

- `ICON_BASE` (`:68`) maps three names and falls back to `kaltoe-timer` via `.get`, so
  `beach.umbrella` degrades to the generic timer icon rather than failing. A dedicated Linux
  icon is a follow-up, not a blocker.
- `render_text_icon` stacks at the **first space** (`:85`). `주말!` has none, so it renders as
  one line, and it is narrower than the `LABEL_GUIDE` of `"OT +88:88"`.

Korean glyph availability in the KDE text-icon path is a hardware check, not a claim —
Pango should resolve it, and the tray already renders no Korean today.

### `KaltoeCore/WorkCalculator.swift` — one guard for the overtime

`dailyOvertime` returns 0 when `isWeekend(record.clockIn)`. That single line covers
`weeklyOvertime`, the cap notifications and the `Week OT` row, because all three are
downstream of it. The week strip needs no change: it is Mon–Fri already, so weekend records
were never rendered there.

## What this deliberately does not do

- No weekend-aware `dailyTarget`. Unreachable for display once the state short-circuits, and
  changing it would move `leaveTime` for everyone.
- No weekend rows in the week strip.
- No change to `leaveTime` / `timeLeft` / `breakDuration`.
- **`StatusLine` keeps emitting `started` and `leaveAt` on a weekend**, gated on the record as
  today. So the Linux tray's detail rows still say `Started` and `Leave at` under a `주말!`
  label. Put to the user and accepted: gating them is more weekend correctness work, which is
  the thing being declined. `StatusLine` needs **no code change at all** — it reads
  `menuBarText`, `iconName` and `urgency.rawValue`, and the new case supplies all three.
- **Clock-in and clock-out hooks still fire on a weekend.** `HookRunner.evaluate` is driven by
  the record, not by the phase, so a Saturday clock-in runs whatever script it is configured
  to run. That is correct — the hooks are about clock events, not about the countdown — and it
  is called out only so the asymmetry does not read as an oversight.

## What this deletes

The subtractions are part of the deliverable, not tidying:

- `FlexRecordParser.swift:106`'s inline weekday expression → the new predicate.
- `WeekSummary.swift:107-111`'s comment explaining why a Saturday record feeds a total it
  cannot show. The problem is gone, so the paragraph goes with it.
- `README.md`'s "**Monday–Friday only — weekend work is deliberately not in the strip**"
  paragraph, including the worked `+1:00` example and its pointer to follow-up 23.
- Follow-ups **23** and **33** in project memory close, rather than being re-documented.

## Testing

All pure, all in `KaltoeCore`:

- `isWeekend` across the boundary: Friday, Saturday, Sunday, Monday, with an injected
  `Asia/Seoul` calendar.
- `computeDisplay` returns `.weekend` on Saturday and Sunday, and does not on a weekday.
- Precedence, both directions: signed out on a Saturday is `.noSession`, not `.weekend`; a
  clocked-in Saturday record is `.weekend`, not `.counting`.
- `dailyOvertime` is 0 for a weekend record that would otherwise be positive — a 9h Saturday.
- `weeklyOvertime` excludes that Saturday: a week with one 9h Saturday and no weekday
  overtime totals 0.
- `labelGlyph`, `labelText`, `spokenLabel` for `.weekend`, and `LabelPhase(.weekend) == .idle`.
- The existing wire guard in `StatusLineTests` gains a `.weekend` row, pinning `주말!` and
  `beach.umbrella`.

Adding a case breaks every exhaustive `switch` over `DisplayState` — `menuBarText`,
`iconName`, `labelGlyph`, `labelText`, `spokenLabel`, `LabelPhase.init`, `fillFraction`. That
is the safety property the previous branch's final review identified, and it means the
compiler enumerates this task's work rather than a checklist doing it.

## Hardware checks

Two, appended to `docs/superpowers/2026-07-30-menu-bar-verification.md`:

- `beach.umbrella` is legible at 9pt inside the ring. It is a detailed glyph and may mush;
  `sun.max` is the cleaner fallback, at the cost of meaning "sunny" rather than "weekend".
- The KDE text-icon path renders `주말!` rather than tofu boxes.

Both are only observable on a Saturday or Sunday.
