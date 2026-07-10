# Time-Off Blocks: Half-Day and Full-Day Leave from work-schedules — Design

**Date:** 2026-07-10
**Status:** Approved

## Problem

Real Flex captures (provided by Jerome, 2026-07-10) show personal leave arrives
as `timeBlocks[]` entries in work-schedules, NOT as `dayOffs[]` (which only
carries holiday/weekend markers: `CUSTOM_HOLIDAY`, `WEEKLY_HOLIDAY`,
`REST_DAY`). Three defects follow:

1. **Full-day vacation breaks sync entirely.** A full-day leave block
   (`type: "FORBIDDEN_TIME_OFF"`, `allDay: true`, `timeOffRegisterUnit: "DAY"`,
   `usedMinutes: 480`) has **no `startTimestamp`/`endTimestampExclusive`**.
   `FlexRecordParser.TimeBlockValue` requires both, so decoding the week
   throws and the app shows "Flex sync failed" for any week containing a
   vacation. Multi-user impact (app is used by 4 people).
2. **Personal leave never reduces the weekly requirement.** `dayOffDates` is
   built only from `dayOffs[]`, which personal leave never populates.
3. **Half-days score as large negative overtime.** A half-day
   (`type: "ANNUAL_TIME_OFF"`, `allDay: false`,
   `timeOffRegisterUnit: "HALF_DAY_PM"`, `usedMinutes: 240`, with real
   timestamps) leaves the day measured against the full 8h target
   (captured 2026-01-02: reads −5h25m instead of ~−1h25m).

Multiple `dayOffs` markers on one date (e.g. 2026-03-01 has both
`WEEKLY_HOLIDAY` and `CUSTOM_HOLIDAY`) are already handled correctly by the
Mon–Fri weekday filter — no change needed.

## Decisions (confirmed with Jerome)

- **Half-day daily math:** the day's net-work target drops by the time-off
  minutes; leave time on such a day adds **no lunch break** when the reduced
  target is ≤ 4h. A smaller off amount (1–2h, if Flex ever sends hourly
  leave) keeps the lunch break.
- **Weekly requirement:** any day with approved time off — half or full —
  deducts the **full** `dayOffDeduction`, same as a holiday weekday.
- **Full-day leave shape:** handled via the time-off block (`allDay: true`),
  merged into the existing `dayOffDates`.
- **Accuracy bonus (in scope):** populate `WorkRecord.flexWorkedNet` from
  actual schedule blocks (ΣWORK − ΣREST) for completed days, replacing the
  fixed-1h-break assumption.

## Design (Approach A: per-day time-off ledger)

Rejected alternatives: (B) crediting time-off minutes as worked time —
inflates "worked" displays and still needs target changes for the live-day
countdown; (C) fractional dayOffs `[Date: Double]` — loses actual minutes,
and the full-deduction decision makes the fraction useless.

### Parsing (`FlexRecordParser`)

- **Generic time-off detection** — type names vary (`ANNUAL_TIME_OFF`,
  `FORBIDDEN_TIME_OFF`; others likely exist), so do NOT match on `type`.
  A time-off block is: `value.usedMinutes > 0` AND
  `value.approval.status == "APPROVED"`.
- `allDay == true` on a Mon–Fri date → insert into `dayOffDates` (exactly
  like a weekday holiday marker today).
- `allDay == false` → `timeOff[startOfDay(date)] = usedMinutes * 60`
  (seconds; sum if multiple partial blocks on one date).
- **Decoder fix:** `startTimestamp`/`endTimestampExclusive` become optional
  in `TimeBlockValue`; add optional `allDay: Bool`, `usedMinutes: Int`,
  `approval: { status: String }`. WORK/REST handling still requires
  timestamps (skip blocks lacking them, as `compactMap` already does).
- **`ParseResult` gains** `timeOff: [Date: TimeInterval]` (keys
  `startOfDay`-normalized, consistent with `dayOffDates`).
- **flexWorkedNet:** for each completed day built from schedules, set
  `flexWorkedNet = Σ WORK durations − Σ (REST ∩ WORK-union overlap)`.
  `dailyOvertime` already prefers `flexWorkedNet` when present; today it is
  always nil. This changes numbers for ALL completed days when the real
  recorded rest ≠ 1h (more faithful to Flex).

### Calculator (`WorkCalculator`)

- `dailyTarget(on:rules:timeOff:)` — target =
  `max(0, dailyWork − offSeconds)`, family-day reduction still applied on
  top (existing precedence: family day reduces `dailyWork` first, then time
  off subtracts; both floored at 0).
- `leaveTime`/`timeLeft` take the day's off-seconds. Break added only when
  the reduced target > 4h; otherwise leave = clockIn + reduced target.
  (Normal days: unchanged — full target, full break.)
- `dailyOvertime` measures against the reduced target.
- `requiredOvertime(dayOffs:timeOff:weekOf:rules:)` — deduction days =
  `dayOffDates ∪ keys(timeOff)` within the week, family day still never
  double-counted, floored at 0 as today.

### Threading & display

- `AppState` gains `@Published var timeOff: [Date: TimeInterval]`, filled
  from `ParseResult`, passed through `recompute` →
  `DisplayState.computeDisplay` → calculator calls.
- Lunch-phase display (`toLunch`/`onBreak`) already self-disables when leave
  time ≤ lunch end (`leave > lunch.endAt` guard), so a HALF_DAY_PM morning
  shows a plain countdown, not lunch phases. No display-logic change
  expected beyond parameter threading.
- `MenuBarView` weekly line uses the merged deduction via the updated
  `requiredOvertime`.

### Testing

- New fixture day shapes (scrubbed, synthetic times/ids) in
  `sample-schedules.json` or a dedicated fixture: half-day
  (WORK + REST + ANNUAL_TIME_OFF HALF_DAY_PM), full-day
  `FORBIDDEN_TIME_OFF` with NO timestamps (regression for the decode
  crash), multi-marker holiday (`WEEKLY_HOLIDAY` + `CUSTOM_HOLIDAY` on a
  Sunday — asserts it does NOT enter `dayOffDates`).
- Parser tests: timeOff map contents, full-day → `dayOffDates`,
  non-approved block ignored, flexWorkedNet = ΣWORK − ΣREST.
- Calculator tests: reduced target; no-lunch leave time at ≤4h reduced
  target; lunch kept at >4h reduced target; weekly deduction merges
  timeOff days with holiday days; family-day no-double-count with a
  half-day on family day.
- Existing tests updated for new signatures; behavior of no-time-off days
  must be unchanged except where flexWorkedNet now reflects actual REST.

## Out of scope

- Pending/rejected time-off requests (ignored: approval must be APPROVED).
- `legalTimeBlocks`, `approvals[]` top-level array (redundant with
  block-level approval).
- Hourly-leave lunch policy beyond the ≤4h/> 4h break rule.
