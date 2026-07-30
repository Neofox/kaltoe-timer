# Week graph in the popover, and the reduced-target caption

Two additions to the macOS popover and the Linux tray menu: a per-day view of the
week, and a line explaining why today's target is shorter than eight hours. Both
are built from data the app already fetches every ten minutes and currently
discards.

## Problem

`FlexClient.fetchWeek` returns three things the UI never shows:

- **`dayOffDates`** — parsed (`FlexRecordParser.swift:99-128`), tested, carried
  through `WeekData` into `AppState.dayOffDates`, and then displayed nowhere and
  used in zero calculations.
- **The per-day records.** `week` holds one record per day, but the popover only
  ever reduces them to a single `Week OT` figure.
- **`timeOff`** — it silently shortens the day's target.

The second problem is worse than mere absence. Two things reduce today's target
without saying so: approved time off, and family day (the last Friday of the
month, `WorkCalculator.isFamilyDay`). On such a day `Leave at` simply reads
earlier than it should, with nothing on screen accounting for it. The compounding
case is genuinely confusing: family day plus 2:00 of approved time off gives a
4:00 target, and because `breakDuration` drops the lunch hour entirely once the
target is at or below half a day, `Leave at` moves **five** hours earlier — not
the four the target reduction alone would suggest. The extra hour is the lunch
that stopped applying, and the caption never names it (see the note at the end of
this section). Nothing in the UI explains either subtraction, let alone their interaction.

**Known limit of the chosen caption**, surfaced in review: on the compounding day
the caption reads `Target 4:00 · family day, time off`, which accounts for four of
the five hours `Leave at` moved. The disappearing lunch break is the fifth and is
never named. That is the pinned contract and ships as-is — a caption that also
explained the break would not fit one 11pt line — but it means the motivating
complaint is only partly answered on exactly the day that motivated it. Recorded
as a follow-up rather than redesigned.

## Visual design

Settled against mockups at the real 280pt width (`.superpowers/brainstorm/`).

**Week rows.** One row per weekday: a 26pt label, a 7pt track, a right-aligned
figure. The track is blue up to that day's target and **orange past it**, with a
1pt notch marking the target — so each row carries its own overtime instead of
only contributing to the total. Today's row fills with a striped blue to hours
worked so far, with a dashed outline continuing to the target.

The right-hand figure is **hours worked**, not overtime. The orange segment
already answers "did I go over", so a `+0:35` beside it states the same fact
twice, and dropping it keeps the track as wide as possible — which matters,
because a 35-minute sliver on an 8-hour scale is inherently small. Signed
overtime per row was rejected for a second reason: it would show `-0:20` on a
short day, but `weeklyOvertime` floors each day at zero, so the column would
visibly fail to add up to the total printed directly beneath it.

**Monday to Friday only, always five rows.** See "Weekends" below.

**The caption** sits under `Leave at`, and only when the target is reduced:

```
Started              09:12
Leave at             13:12
  Target 4:00 · family day, time off
Time left          00:31:00
```

It costs nothing on an ordinary day, and it attaches the explanation to the row
that actually surprised the user.

The string is pinned as `Target <hm> · <reasons>`, reasons being `family day`
and/or `time off`, comma-joined in that order and carrying no amount. Two
mockups used a shorter `4h day · …`; the pinned form wins because the same string
is shipped to the Linux tray verbatim (below), and it is the form that was
reviewed there. An always-present `Target` row and a per-cause
deduction row were both mocked up and rejected — the former adds a row to every
ordinary day, the latter can grow to two rows and never states the target the
deductions add up to.

## Architecture: one summary, both platforms

The popover computes its own weekly overtime today (`MenuBarView:125`) while
`recompute` computes the same figure every second for the menu bar pill — two
independent passes that can disagree, logged as follow-up item 10. Adding five
rows of per-day arithmetic to the view would multiply that, and `HeadlessState`
would then hand-derive the same values a third time for Linux.

Instead, one value type in `KaltoeCore` is computed once per tick and consumed by
all three surfaces:

- `AppState.recompute` builds it, publishes it, and the SwiftUI view renders it
  and computes nothing. This closes follow-up item 10 as a side effect: the pill
  and the popover become structurally incapable of disagreeing.
- `HeadlessState.status` builds it from the same function and serialises it.

Every new number therefore lands behind a plain-value test in `KaltoeCore`, with
no view and no daemon involved.

## New in KaltoeCore

`Sources/KaltoeCore/WeekSummary.swift`:

```swift
public struct DaySummary: Equatable, Sendable {
    public var date: Date
    public var label: String          // "Mon" — fixed en_US_POSIX short symbols
    public var worked: TimeInterval?  // nil = no record that day
    public var target: TimeInterval   // the notch; family-day- and time-off-aware
    public var overtime: TimeInterval // max(0, worked - target)
    public var isDayOff: Bool         // from dayOffDates
    public var isOngoing: Bool        // still on the clock
}

public struct WeekSummary: Equatable, Sendable {
    public var days: [DaySummary]     // always 5, Mon-Fri, in order
    public var overtime: TimeInterval // WorkCalculator.weeklyOvertime, unchanged
    public var cap: TimeInterval
    public var targetNote: String?    // nil unless today's target is reduced
}

public static func compute(from: WeekData, now: Date, rules: WorkRules,
                           calendar: Calendar = .current) -> WeekSummary
```

`compute` sources its records from `weekData.weekIncludingManual(now:)`, so a
manual start appears in the rows exactly as it already does in the total.

`worked` is derived per record:

- **Completed:** `flexWorkedNet ?? max(0, clockOut - clockIn - breakDuration(target:))`,
  matching what `dailyOvertime` already does.
- **Open:** `max(0, now - clockIn - breakTaken(clockIn:now:rules:))`.

### Two supporting functions

**`breakTaken(clockIn:now:rules:)`** — the lunch *already consumed*, as the
overlap of `[clockIn, now]` with `[lunchStart, lunchEnd]`, capped at the day's
`breakDuration`. This is why today's bar cannot simply reuse the existing
break-subtraction: deducting the full hour from the start would pin the bar at
zero until 10:12 on a 09:12 start.

It deliberately uses `rules.lunchStart` (11:30), **not** `lunchWindow`'s
`leaveAt`, which is shifted earlier by `lunchEarlyLeave`. That shift exists for
the "you may leave for lunch now" countdown; break *accounting* should follow the
official window.

**`targetReduction(on:rules:timeOff:)`** — returns the day's target together with
why it is reduced, as the single source for the caption. The composed string
lives in `KaltoeCore` as `targetNote` rather than being assembled per platform:
the Linux tray is Python, and duplicating the wording there would let the two
surfaces drift.

### Row overtime comes from `dailyOvertime`, not from `worked`

An earlier draft of this design claimed `max(0, worked - target)` equals
`WorkCalculator.dailyOvertime` "in every case that occurs", and derived the row's
overtime that way. **That was wrong.** Clock in after the lunch window closes and
`breakTaken` stays 0 for the rest of the day, while `leaveTime` still adds the
full break. A 13:00 start against an 8h target is due out at 22:00, so at 22:30
the naive form reads +1:30 where `dailyOvertime` reads +0:30 — and each row would
contradict the weekly total printed directly beneath it, which is precisely the
failure that got the signed-overtime row layout rejected.

So `DaySummary.overtime` is `max(0, dailyOvertime(record:now:rules:timeOff:))` —
the same function that feeds `weeklyOvertime`, floored the same way. The rows
agree with their total structurally rather than by coincidence, which is what the
earlier draft should have insisted on in the first place.

`worked` remains the bar's length and the row's right-hand figure. The accepted
consequence, stated correctly on the second attempt: the **accent fill** is driven
by `worked`, which carries no break deduction after a start later than the lunch
window, so it can reach the target notch up to a full break before the pill counts
down to zero. The **orange segment** is driven by `overtime`, i.e. `dailyOvertime`,
so it tracks the pill exactly and can never appear early. An earlier draft of this
paragraph blamed the orange segment; that was backwards.

## macOS view

`MenuBarView.weekSummary` gains the five rows above the existing `Week OT` total
and stops calling `WorkCalculator.weeklyOvertime`. A new `WeekBarRow` in its own
file draws the track with `RoundedRectangle`s — not Swift Charts, because the
popover is a fixed 280pt so the track width is known statically, needing no
`GeometryReader` and no framework for roughly forty lines of shapes.

Rows render whenever the week holds any record, including when signed out — the
same rule `Week OT` already follows, which keeps stale-but-real data visible
rather than blanking it.

One further case falls out of finally reading `dayOffDates`: when **today** is a
day off there is no record, so the popover currently says "Not clocked in yet".
It will say **"Day off"**.

Cost: roughly 110pt of height, taking the popover from about 250 to about 360pt.

## Linux tray

The tray gets the same data as figures, with no bar:

```
Started 09:12
Leave at 13:12
  Target 4:00 · family day, time off
Time left 0:31:00
---------------------
Mon   8:35   +0:35
Tue   9:10   +1:10
Wed   7:40
Thu   off
Fri   4:29   · on the clock
---------------------
Week OT +1:45 / 12:00
```

Rows here carry the day's overtime as a figure, because without a bar there is
nothing else to convey it. It is **not** signed: `DaySummary.overtime` is floored
at zero, so a day short of target shows its hours alone with nothing after them —
`Wed   7:40`. Only a day that actually earned overtime gets a `+0:35`. An earlier
draft of this section said "signed", which the rejected macOS layout would have
been but this one is not.

Bars were considered and rejected on a hard constraint: tray rows are
`Gtk.MenuItem` labels serialised over DBusMenu to the host panel, which carries
text, icons and checkmarks but not custom widgets. The cairo/Pango code already
in `kaltoe-tray.py` renders the *tray icon* PNG, which is a different path
entirely. Block-glyph bars were the remaining option and lose too much: at one
cell per hour, 35 and 70 minutes of overtime both round to a single cell, making
Monday and Tuesday above indistinguishable, and glyph widths depend on the
panel's theme font. **Verify the DBusMenu limitation on the Fedora KDE setup
before implementing** — the conclusion is from the protocol's capabilities, not
from a test on that machine.

## Protocol change

`StatusLine` gains two optional fields, both gated on `hasSession` exactly as
`weekOvertime` already is:

```swift
public var days: [DayLine]?
public var targetNote: String?
public var weekOvertimeCap: Int?

public struct DayLine: Codable, Equatable, Sendable {
    public var label: String
    public var worked: Int?      // seconds, whole minutes; nil = no record
    public var target: Int       // seconds
    public var overtime: Int     // seconds
    public var isDayOff: Bool
    public var isOngoing: Bool
}
```

`weekOvertimeCap` is not strictly needed by this change, but the tray currently
renders `Week OT +1:45` where the popover renders `1:45 / 12:00`, and shipping
the cap is one field on a struct already being extended. It closes the
`StatusLine` half of follow-up item 2.

`DayLine`'s intervals are **integer seconds truncated to the whole minute**, for
the same reason `weekOvertime` is (`StatusLine.swift:31`): the daemon emits on
change (`main.swift:39`), so a second-resolution `worked` for the ongoing day
would turn a once-per-minute emission into once per second — and on Plasma every
emission drives the cache-defeating temp-PNG icon re-render.

The tray does not interpolate the current day's bar between emissions. A
per-minute update to a figure that reads in hours and minutes is imperceptible,
and `Time left` already gets its per-second smoothness client-side from
`leaveAt`.

## Testing

`WeekSummaryTests` in `KaltoeCoreTests`, against fixed dates and a literal
`WeekData`:

- five rows always, Monday first, regardless of which days hold records
- `isDayOff` set from `dayOffDates`
- `flexWorkedNet` preferred over the clock-out subtraction when present
- ongoing `worked` correct before, during and after the lunch window — the
  `breakTaken` cases, including a target small enough that the break is zero
- per-day `target` reflecting family day and time off, separately and stacked
- per-day `overtime` summing to `WorkCalculator.weeklyOvertime` for the same week
- `targetNote` nil / family day / time off / both
- the manual-start record appearing as a row

`KaltoeDaemonTests` gains coverage for `status()` emitting `days` and
`targetNote`, and for both being omitted when signed out. This overlaps
follow-up item 20, which notes the existing `dayOffDates`/`timeOff` plumbing gaps
in `HeadlessState`.

`AppStateTests` gains one case asserting `recompute` publishes a summary whose
`overtime` matches the figure driving the pill.

Existing calculations are untouched: `leaveTime`, `timeLeft`, `dailyOvertime`,
`weeklyOvertime` and `DisplayState` keep their current behaviour, so no test of
theirs should need editing. Per the project's verification note, the warning gate
is `rm -rf .build && swift build --build-tests`, run once, for both `.build` and
`.build-linux`.

## Weekends, and what this deliberately leaves alone

`FlexRecordParser` gates `dayOffDates` and `timeOff` to weekdays (`:106`, `:110`,
`:117`) but **does not gate work records** (`:155`), so a Saturday clock-in
produces a real record. `WorkCalculator.dailyTarget` (`:89`) has no weekend
awareness — every day's target is eight hours. A three-hour Saturday therefore
computes `max(0, 3h - 8h)` and earns **zero** overtime, and while still on the
clock `Leave at` reads clock-in plus nine hours. Nobody chose this; it has simply
never come up.

Fixing it means weekend targets of zero, which changes the menu bar countdown,
the weekly total and the cap notifications for all four users — well beyond a
menu-data change. So: **weekdays only, and the gap is recorded as a follow-up.**

The consequence to be aware of: a weekend record still feeds `weeklyOvertime`,
so a nine-hour Saturday would add `+1:00` to the total with no row on screen
explaining it. That is already true today; this change only makes it nameable.

Also out of scope: any change to `DisplayState`, the menu bar pill, or the limit
notifications.
