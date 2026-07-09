# FlexTimer v2 — Day Phases + Overwork Warning

**Date:** 2026-07-09
**Status:** Approved
**Extends:** `2026-07-09-flextimer-design.md` (v1, shipped)

## Purpose

Make the menu bar phase-aware through the workday — countdown to lunch in the
morning, a BREAK state during lunch, the existing leave countdown in the
afternoon — and color the display as leave time approaches so the user does
not overwork.

## New Menu Bar Timeline (clocked in, day open)

| Window                                | Menu bar                                | SF Symbol icon   |
| ------------------------------------- | --------------------------------------- | ---------------- |
| clock-in → lunch-leave (11:20)        | countdown to 11:20, e.g. `1:42`         | `fork.knife`     |
| lunch-leave → lunch-end (11:20–12:30) | `BREAK 0:48` counting down to 12:30     | `cup.and.saucer` |
| lunch-end → leave time                | countdown, e.g. `2:34` (v1 behavior)    | `timer`          |
| past leave time                       | `OT -2:59` weekly counter (v1 behavior) | `timer`          |

Unchanged v1 states: not clocked in `--:--`, no session `—` (icon `timer`,
no color). Already clocked out → OT display (no color).

### Phase rules

- **Lunch-leave time** = official lunch start (11:30) minus the early-leave
  allowance (10 min) = 11:20.
- Phases apply only when still ahead: clock-in at 11:25 → BREAK phase until
  12:30 then afternoon; clock-in at 13:00 → straight to leave countdown.
  Degenerate guard: if leave time ≤ lunch-end (absurdly early clock-in),
  skip lunch phases entirely.
- Lunch phases are **display only** — leave time, daily/weekly overtime math
  are untouched from v1 (leave = clock-in + 8h + 1h; fixed 1h break).

### Settings (UserDefaults, like v1 rules)

| Key                                   | Default | Meaning                          |
| ------------------------------------- | ------- | -------------------------------- |
| `lunchStartHour` / `lunchStartMinute` | 11 / 30 | official break start             |
| `lunchEndHour` / `lunchEndMinute`     | 12 / 30 | break end / work resumes         |
| `lunchEarlyLeaveMinutes`              | 10      | allowed early departure to lunch |

Stored alongside the existing rule keys in `SettingsStore`; missing keys →
defaults.

## Overwork Warning (Urgency)

`Urgency` is computed with the display state as a pure function:

| Level      | Condition                                                                               | Color             |
| ---------- | --------------------------------------------------------------------------------------- | ----------------- |
| `normal`   | everything else                                                                         | primary (no tint) |
| `warning`  | ≤ 30 min before leave time, still clocked in                                            | orange            |
| `critical` | ≤ 10 min before leave time, or past leave time while the day is still open (clocked in) | red               |

- Color applies to the whole label (icon + text).
- Lunch phases (`toLunch`, `onBreak`) are always `normal` — no one overworks
  toward lunch.
- After clock-out, OT display is `normal` (not overworking anymore).
- Not clocked in / no session → `normal`.
- Thresholds (30/10 min) are constants, not settings (YAGNI).

## Implementation Shape

Extends existing units; no new architecture:

- **WorkRules** (`WorkCalculator.swift`): three new fields with defaults —
  `lunchStart` (minutes from midnight, 690), `lunchEnd` (750),
  `lunchEarlyLeave` (seconds, 600). Codable defaults preserved.
- **DisplayState** (`DisplayState.swift`): two new cases
  `toLunch(timeLeft:)` and `onBreak(timeLeft:)`; `compute(...)` gains the
  phase logic (lunch times resolved against the current calendar day in the
  system time zone). Urgency needs `now`/`leaveTime` context, so `compute`
  returns a `MenuDisplay` struct: `{ state: DisplayState, urgency: Urgency }`
  (enum normal/warning/critical). Callers that only need the state read
  `.state`; the label reads both. Pure and testable as one unit.
- **menuBarText**: `toLunch` → `Formatting.hm(left)`; `onBreak` → `"BREAK "
    - Formatting.hm(left)`. Existing cases unchanged.
- **Menu bar label** (`FlexTimerApp.swift` + small helper): maps state →
  SF Symbol name, urgency → `Color?` (nil/orange/red), applied to the HStack.
- **SettingsStore**: reads the new keys into WorkRules.
- **MenuBarView** (dropdown): one addition — during the break phase, a row
  `Back at` / `12:30` above the existing detail rows. Otherwise unchanged.

## Testing

Pure-logic unit tests on `DisplayState.compute` + urgency (Seoul-pinned dates,
existing `d(...)` helper):

- Boundaries: 11:19:59 → toLunch, 11:20 → onBreak, 12:29:59 → onBreak,
  12:30 → counting.
- Late clock-in: 11:25 → onBreak; 13:00 → counting (no lunch phases).
- Urgency: 31 min before leave → normal; 30 min → warning; 10 min → critical;
  past leave with open day → critical; past leave clocked out → normal;
  toLunch/onBreak always normal.
- Settings: overridden lunch keys shift the boundaries.
- All existing v1 tests keep passing (copy for counting/OT unchanged).

## Out of Scope (YAGNI)

- macOS notifications (revisit later if color proves insufficient).
- Reading actual REST records from Flex to time the break (fixed window is
  how the company operates; Flex auto-registers 11:30–12:30 anyway).
- Configurable urgency thresholds.
