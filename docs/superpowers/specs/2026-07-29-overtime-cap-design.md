# Overtime: from weekly mandate to weekly cap

## Problem

The company has dropped its forced-overtime mandate. 칼퇴타이머 was built around
it: `WorkRules.weeklyOvertime` is a 5h/week _requirement_, and the menu bar's
overtime state reports how far short of that requirement you are (`OT -2:59`).
That number no longer means anything.

Two company rules remain, and they run the opposite direction — they are
ceilings, not floors:

- no more than 12 hours of overtime per week
- no overtime after 22:00

So this is not a removal. It is an inversion: the same weekly figure that used
to be a target to reach becomes a limit not to cross.

## Definition of overtime

Overtime is the time worked beyond the 8 mandatory hours on a given day.

It depends only on hours worked, never on when they are worked. Clocking in at
09:00 and out at 19:00 is 10h elapsed minus the 1h lunch = 9h worked = 1h of
overtime. Clocking in at 07:00 and out at 17:00 is the same 1h of overtime.
This is already how `WorkCalculator.dailyOvertime` and `leaveTime` compute —
relative to clock-in, not to the wall clock. Only the 22:00 cutoff is a
wall-clock rule.

A day worked short of 8h has no hours _over_ 8, so it contributes **zero** to
the week — it does not offset a long day. The weekly figure is therefore a
**gross** sum, not a net one. This is a change from the old behaviour, where
negative days deliberately offset positive ones because the 5h quota was a net
target.

## Approach

Delete the mandate, add the two ceilings, and re-point the menu bar at the
daily figure while the popover keeps the weekly one.

`WorkRules.weeklyOvertime` is read at exactly one place —
`WorkCalculator.requiredOvertime`. Everything else consumes that function's
output. Deleting it removes the mandate wholesale.

`dayOffDeduction` and `familyDayDeduction` exist only to shrink the
requirement, and a holiday does not lower a _maximum_, so both are deleted with
it. `familyDayEarlyLeave` is unrelated — it shortens the daily target and
therefore the leave-time countdown — and is untouched.

`dayOffDates` loses its only consumer. The parsing, the `WeekData`/`AppState`
threading, and its `FlexClientTests` coverage are deliberately **kept**: it is
working code covering real Flex API data and the obvious input for any future
holiday awareness. Only the deduction that used it goes.

Concretely: `FlexClient` still parses it, `WeekData` and `AppState` still
carry it, and `FlexClientTests` still covers it — but `computeDisplay` and
`weeklyOvertime` both drop their `dayOffs` parameter, since neither consumes
it any more.

## Components

### `KaltoeCore/WorkCalculator.swift` — rules and math

`WorkRules` loses three fields and gains two:

```swift
// removed: weeklyOvertime, dayOffDeduction, familyDayDeduction
public var weeklyOvertimeCap: TimeInterval = 12 * 3600  // ceiling on weekly overtime
public var overtimeCutoff: TimeInterval = 22 * 3600     // seconds from midnight; no overtime after this
```

`overtimeCutoff` follows the seconds-from-midnight convention already used by
`lunchStart` and `lunchEnd`.

`requiredOvertime` is deleted.

`weeklyOvertime` drops its now-unused `dayOffs` parameter and becomes a gross
sum, with each day floored at zero:

```swift
public static func weeklyOvertime(records: [WorkRecord], timeOff: [Date: TimeInterval] = [:],
                                  now: Date, rules: WorkRules,
                                  calendar: Calendar = .current) -> TimeInterval {
    records.reduce(0) { $0 + max(0, dailyOvertime(record: $1, ...)) }
}
```

`dailyOvertime` itself is unchanged and stays **signed** — it still returns a
negative value for a short day. Only the weekly aggregation floors at zero.

Two new predicates, kept pure so they are testable without a clock:

```swift
public static func isPastOvertimeCutoff(now: Date, rules: WorkRules, calendar: Calendar = .current) -> Bool
public static func hasReachedWeeklyCap(weeklyOvertime: TimeInterval, rules: WorkRules) -> Bool
```

### `KaltoeCore/DisplayState.swift` — what the menu bar shows

`case overtime(weekly: TimeInterval)` becomes `case overtime(today: TimeInterval)`.

`menuBarText` renders today's figure, keeping the signed format so a short day
reads as `OT -0:45`:

```swift
case .overtime(let today): return "OT " + Formatting.signedHM(today)
```

`computeDisplay` still computes the weekly total — not to display it, but to
decide urgency. The state is reached exactly as before (clocked out, or past
leave time while still clocked in); only the payload and the urgency change:

| Situation                                             | Urgency  |
| ----------------------------------------------------- | -------- |
| Weekly total ≥ `weeklyOvertimeCap`                    | critical |
| Past `overtimeCutoff`, still clocked in               | critical |
| Past leave time, still clocked in, within both limits | warning  |
| Clocked out, day settled, within both limits          | normal   |

The cap check ignores clock state — having worked 12h of overtime this week is
worth flagging whether or not you are currently on the clock. The cutoff check
applies only while clocked in, since it is about working late, not about having
worked late.

This is a change from current behaviour, where being past leave time while
clocked in is `critical`. Overtime is no longer a violation in itself, so it
drops to `warning` and the two real limits take over `critical`.

### `KaltoeCore/LimitNotifier.swift` — telling you to stop

A new type mirroring the existing `SessionNotifier`: pure decision logic with
injectable delivery, so tests never touch `UNUserNotificationCenter`.

```swift
public final class LimitNotifier {
    public init(deliver: @escaping (String, String) -> Void, defaults: UserDefaults)
    public func evaluate(weeklyOvertime: TimeInterval, clockedIn: Bool, now: Date, rules: WorkRules)
}
```

Two triggers:

- **Weekly cap reached** — fires when `weeklyOvertime >= weeklyOvertimeCap`.
- **Past cutoff** — fires when `now` is past `overtimeCutoff` and `clockedIn`.

Dedupe is the substance of this component, not an afterthought: `recompute`
runs every second, so an undeduped notifier would fire 3,600 times an hour. The
cap notification is keyed on the week-start date and fires once per week; the
cutoff notification is keyed on the calendar date and fires once per day. Both
keys are written to `UserDefaults`, so relaunching the app at 22:30 does not
re-notify.

Attached in `AppState.start()` only — the same pattern `HookRunner` and
`SessionNotifier` already use so unit tests calling `recompute` never fire
notifications.

### `FlexTimer/MenuBarView.swift` — the popover

The Week OT row stays and gains the ceiling for context, so the limit is
visible well before it fires:

```
Week OT        3:20 / 12:00
```

The weekly value is the gross sum; the denominator is `weeklyOvertimeCap`.

### `KaltoeCore/SettingsStore.swift` — keys

Removed: `weeklyOvertimeHours`, `dayOffDeductionHours`, `familyDayDeductionHours`.
Added: `weeklyOvertimeCapHours`, `overtimeCutoffMinutes`.

No migration is needed. Existing users have the removed keys sitting in their
`com.perso.flextimer` domain; nothing reads them any more and a stale key in
`UserDefaults` is inert.

### Linux surface

`StatusLine.weekOvertime` keeps its name, type, and minute-truncation — only
the meaning of the value changes (gross total rather than net-against-quota),
so no structural change reaches `HeadlessState` or `kaltoe-tray.py`. The tray
label renders `StatusLine.text`, which now carries today's figure rather than
the week's; `LABEL_GUIDE = "OT +88:88"` remains wide enough.

## Data flow

```
WorkRecord[] ──> dailyOvertime (signed, per day)
                      │
        ┌─────────────┴──────────────┐
        │                            │
   today's value              weeklyOvertime
   (menu bar text)          (gross: Σ max(0, daily))
        │                            │
        │                   ┌────────┴────────┐
        │                   │                 │
        └──> DisplayState.overtime(today:)   popover "Week OT x / 12:00"
                   │                          │
             urgency ◄─── hasReachedWeeklyCap ┘
                   ▲
                   └─── isPastOvertimeCutoff ──> LimitNotifier ──> notification
```

## Error handling

No new failure paths. Both new predicates are total functions over their
inputs. `LimitNotifier`'s delivery closure is injected and its failures are the
caller's concern, matching `SessionNotifier`. A missing dedupe key in
`UserDefaults` reads as "never notified", which is the correct default for a
fresh install.

## Testing

**Deleted with the code:** the `requiredOvertime` tests and the
`dayOffDeduction`/`familyDayDeduction` tests in `WorkCalculatorTests` — roughly
14 assertions across `testRequiredOvertime*`, `testFamilyDayVacationCoincidenceDeductsOnce`,
and `testWeeklyOvertimeUsesAdjustedRequirement`.

**Rewritten:** the `weeklyOvertime` tests, for the gross sum. One case matters
most and did not exist before — a week mixing a long day and a short day must
total the long day's overtime alone, proving the short day contributes zero
rather than offsetting.

**New:**

- The four-way urgency table in `DisplayStateTests`, including the boundary
  where the cap is reached exactly and the boundary at 22:00.
- `LimitNotifierTests`: fires once on first crossing; does **not** fire on the
  next tick; does not re-fire after a simulated relaunch with the same
  `UserDefaults`; the cap notification re-arms in a new week and the cutoff
  notification re-arms on a new day.
- `isPastOvertimeCutoff` and `hasReachedWeeklyCap` directly, with an injected
  calendar so no test depends on the machine's clock.

**Kept untouched:** `familyDayEarlyLeave` coverage (`testFamilyDayLeaveTimeIsTwoHoursEarlier`
and friends), all leave-time/lunch/time-off tests, and the `dayOffDates`
parsing tests in `FlexClientTests`.

## Verification

`swift test` covers the arithmetic and the dedupe. By eye, after
`./scripts/bundle.sh`:

1. Menu bar past leave time shows today's overtime in orange, not the week's.
2. Popover Week OT reads `x / 12:00`.
3. A short day shows a negative daily figure but does not reduce the weekly
   total.
4. Setting `overtimeCutoffMinutes` to a few minutes ahead produces exactly one
   notification at the crossing, and none on subsequent ticks.

## Documentation

`README.md` needs edits at the top-level description (line 3), the Overtime
phase spec (12-16), the popover description (30), the settings block (70,
79-80, 91-93), and the calculations section (165-167). `linux/README-linux.md:48`
describes the weekly counter and needs the same treatment.

All markdown edits must be applied via Bash rather than Edit/Write: a global
prettier `PostToolUse` hook reflows markdown on write and has already corrupted
unrelated lines in this README once.

## Out of scope

- Removing `dayOffDates` parsing and plumbing — deliberately retained, see Approach.
- Any change to `familyDayEarlyLeave`, lunch handling, or leave-time computation.
- Blocking or preventing work past a limit. The app notifies; it does not enforce.
- Backfilling or migrating historical overtime figures.
