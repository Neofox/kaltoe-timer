# 출근/퇴근 Hooks — Design

**Date**: 2026-07-09
**Status**: Approved

## Overview

Let users run their own shell scripts when 칼퇴타이머 detects clock-in (출근) and clock-out (퇴근). The app stays basic: its entire contribution is "run two script files if they exist." All automation logic (caffeinate, Slack, screen lock, `claude -p`, …) lives in user-owned scripts.

## Goals

- Fire a user script once per day on detected 출근, and once per day on detected 퇴근.
- Zero configuration UI, zero new settings, zero dependencies. No hooks directory → no behavior change.
- Scripts can start long-running background processes (e.g. `caffeinate`) that outlive the script.

## Non-Goals

- No process management: the app never tracks, restarts, or kills what scripts spawn. (Pidfile patterns are the user's job; documented in README.)
- No additional events (leave-time reached, lunch, overtime warnings). Two events only; more can be added later if asked for.
- No output capture, logging UI, or failure surfacing. Fire-and-forget.

## Hook Interface (user-facing)

- Directory: `~/Library/Application Support/칼퇴타이머/hooks/`
- Two optional executables:
    - `on-clock-in`
    - `on-clock-out`
- Missing or non-executable file → silently skipped.
- Environment variables passed to the script (on top of the app's environment):
    - `KALTOE_EVENT` — `clock-in` or `clock-out`
    - `KALTOE_CLOCK_IN` — clock-in time, ISO8601
    - `KALTOE_CLOCK_OUT` — clock-out time, ISO8601 (clock-out event only)
- Launched detached via `Process`; the app does not wait on the script or read its output. Backgrounded children (`caffeinate &`) survive after the script exits — guaranteed semantic, documented.

## Trigger Semantics

The app _detects_ rather than _performs_ 출근/퇴근 (Flex API sync every 10 min, or manual start entry). Hooks fire on observed state of today's record, **deduplicated once per event per day** via UserDefaults keys:

- Key format: `hookFired-clockIn-yyyy-MM-dd` / `hookFired-clockOut-yyyy-MM-dd` (same date-key style as existing `manualStart-` keys).
- **출근**: today's record exists (from Flex _or_ manual entry) and the clock-in key for today is unset → fire, set key.
- **퇴근**: today's record has non-nil `clockOut` and the clock-out key for today is unset → fire, set key.

Consequences (intended):

- **Fire-on-late-detection**: if the app launches at 2pm after the user clocked in that morning, the 출근 hook still fires — late, but exactly once. Login-item users whose Mac boots after clock-in are covered.
- Restarting the app mid-day never re-fires (keys persist in UserDefaults).
- 퇴근 detection latency is up to ~10 min (Flex refresh interval). Only Flex data can signal clock-out; manual entries have no clock-out.
- If a record's `clockOut` later reverts (re-clock-in), the day's hooks do not re-fire. Once per event per day.

Stale `hookFired-*` keys from previous days are lazily removed when a new day's key is written.

## Implementation

- **New file** `Sources/FlexTimer/HookRunner.swift` (~60 lines):
    - `evaluate(today: WorkRecord?, now: Date)` — transition detection + dedupe + fire.
    - Injected `UserDefaults` and an executor closure `(URL, [String: String]) -> Void` so logic is testable without spawning processes; the default executor launches `Process` detached.
- **One call site**: `AppState.recompute(now:)` calls `hookRunner.evaluate(today:now:)`. `recompute` already runs every second, so hook firing is as fresh as the data.

Alternatives considered and rejected:

- Hooking `DisplayState` transitions — conflates lunch/overtime phases with clock state.
- Hooking `refresh()` API responses only — misses manual-entry 출근.

## Testing

Unit tests for `HookRunner` with injected `UserDefaults` (fresh suite per test) and a spy executor:

- Fires clock-in once when a record appears; not again on subsequent evaluates.
- Fires clock-in for manual-entry records.
- Fires clock-out once when `clockOut` becomes non-nil.
- No fire when record is nil / when already fired today.
- Late detection: first evaluate with an existing record fires.
- Correct env vars passed for each event.
- Missing/non-executable script handling lives in the default executor (thin, not unit-tested).

## README

New "Hooks" section documenting the directory, env vars, fire-and-forget semantics, `chmod +x` requirement, and three examples:

`on-clock-in`:

```bash
#!/bin/zsh
caffeinate -d & echo $! > /tmp/kaltoe-caffeinate.pid
claude -p "prepare my morning briefing" > /dev/null 2>&1 &
```

`on-clock-out`:

```bash
#!/bin/zsh
[ -f /tmp/kaltoe-caffeinate.pid ] && kill "$(cat /tmp/kaltoe-caffeinate.pid)" 2>/dev/null
rm -f /tmp/kaltoe-caffeinate.pid
pmset displaysleepnow   # lock the screen (with default require-password-immediately)
```

Notes in README: 퇴근 hook latency (≤10 min), morning `caffeinate -d` conveniently guarantees the Mac is awake for the clock-out hook, `pmset` needs no special permissions.
