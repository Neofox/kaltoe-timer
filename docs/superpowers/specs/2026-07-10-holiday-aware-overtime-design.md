# Holiday/Vacation-Aware Weekly Overtime + Family Day — Design

**Date**: 2026-07-10
**Status**: Approved

## Overview

The weekly overtime counter assumes a full 5-day week: it starts at −5:00 every Monday regardless of holidays or vacations, so any week with a day off shows a wrong (demotivating) number. Additionally, the company's "family day" (last Friday of each month) allows leaving 2h early and reduces the week's overtime requirement by 1h — the app knows nothing about it.

## Rules (from the user)

1. **Holiday/vacation deduction**: each holiday or vacation weekday in the week deducts **1h** from the required weekly overtime (default 5h). Half-days (반차) also deduct the full 1h.
2. **Family day**: the last Friday of every month.
    - Daily work target that day is **6h** instead of 8h (leave 2h early is free): leave time = clock-in + 6h + 1h break; the day's overtime contribution is measured against 6h.
    - The week containing family day gets an additional **−1h** requirement deduction.
    - If family day itself is a holiday/vacation day, it deducts only once (no −2h double-count).

Example: week with a Thursday public holiday + family-day Friday → required = 5 − 1 − 1 = 3h; Friday's countdown targets 6h of work.

## Detection

- **Holiday/vacation day**: in the work-schedules response (already fetched), a day is a deduction day when it falls Mon–Fri AND its `dayOffs` array contains at least one entry whose `type` is neither `REST_DAY` nor `WEEKLY_HOLIDAY` (the observed weekend markers). Unknown type strings count as deduction days — we have not yet captured how Flex encodes annual leave or public holidays, so the rule is deliberately permissive. **Verify against the next real vacation/holiday week and tighten if needed.**
- **Family day**: computed locally — the last Friday of the calendar month of the date in question. No API involvement.

## Data Flow

- `FlexRecordParser.parse` currently returns `[WorkRecord]` and drops day-level metadata. It now also returns the set of deduction days (as `yyyy-MM-dd`-keyed dates in the schedule's timezone), applying the Mon–Fri + non-weekend-marker rule above.
- `FlexClient.fetchWeek` passes both through; `AppState` stores `dayOffDates: Set<Date>` (startOfDay dates) alongside `week`.
- `WorkCalculator` gains:
    - `isFamilyDay(_ date: Date, calendar:) -> Bool` — last Friday of month.
    - `dailyTarget(on day: Date, rules:) -> TimeInterval` — `rules.dailyWork` minus the family-day reduction when applicable; used by `leaveTime`, `timeLeft`, and `dailyOvertime` (all currently hardcode `rules.dailyWork`).
    - `weeklyOvertime(records:dayOffs:now:rules:)` — required = `rules.weeklyOvertime − rules.dayOffDeduction × deductionCount − rules.familyDayDeduction × (week contains family day ? 1 : 0)`, where `deductionCount` excludes family day itself if it is also a day-off. Required is floored at 0 (a week of vacation cannot make overtime negative-required).
- Display state (countdown, orange/red pills, "Back at" row) needs no logic changes: it derives from `leaveTime`, which now respects the family-day target.

## Configuration (SettingsStore, `defaults write`, consistent with existing rules)

- `dayOffDeductionHours` (default 1.0) — hours deducted per holiday/vacation weekday.
- `familyDayEarlyLeaveHours` (default 2.0) — daily-target reduction on family day; `0` disables family day entirely (both effects).
- `familyDayDeductionHours` (default 1.0) — weekly requirement deduction for a family-day week.

New `WorkRules` fields: `dayOffDeduction`, `familyDayEarlyLeave`, `familyDayDeduction` (seconds), defaults matching the above.

## Edge Cases

- **Manual (offline) mode**: manual entries carry no day-off data; deductions apply only from synced Flex data. A fully offline week shows the unadjusted requirement — accepted.
- **Family day + vacation same day**: single −1h (family-day deduction applies; the day is excluded from the day-off count).
- **Vacation-heavy week**: required overtime floors at 0; the counter then shows only accumulated overtime (≥ 0 contribution days).
- **Family day overtime**: working past the 16:00-style family-day leave time accrues overtime against the 6h target (open-record accrual starts at family-day leave time, matching existing semantics).
- **Month boundary**: family-day math uses the calendar month of the day being evaluated; a week spanning two months gets the deduction only if its actual last-Friday falls inside that week.

## Testing

All pure-function level:

- Parser: fixture gains a weekday with a non-weekend `dayOffs` entry (synthetic type e.g. `TIME_OFF`) → reported as deduction day; weekend `REST_DAY`/`WEEKLY_HOLIDAY` days are not; half-day (dayOff + WORK blocks same day) is.
- Calculator: last-Friday detection across month lengths and year boundary; family-day leave time/daily target; weekly requirement with 0/1/2 deduction days; family-day week; family-day-is-vacation coincidence; floor at 0.
- AppState: menu text reflects adjusted requirement (one integration-style test in the existing style).

## README

Update the overtime bullet ("resets to −5:00 every Monday") to describe the adjusted requirement, family day behavior, and the three new `defaults write` keys.
