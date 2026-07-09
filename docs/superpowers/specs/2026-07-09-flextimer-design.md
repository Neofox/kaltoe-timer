# FlexTimer — macOS Menu Bar Work Countdown

**Date:** 2026-07-09
**Status:** Approved

## Purpose

A native macOS menu bar app that reads the user's clock-in time from flex.team
and shows, at a glance, when they can leave (퇴근) and where they stand on the
week's required overtime.

## Menu Bar Behavior (smart single value)

- **During the workday** (before leave time): show the daily countdown, e.g. `⏳ 2:34`.
- **After leave time**: switch to the weekly overtime position, e.g. `OT -2:59`.
- Value ticks every second (or every minute for the OT display — see Open Choices).

### Dropdown (on click)

```
Started:        08:59
Leave at:       17:59
Time left:      2:34:12
──────────────────────
Week OT:        -2:59  (2:01 / 5:00)
──────────────────────
↻ Refresh from Flex
⚙ Settings
⏻ Quit
```

## Business Rules

### Daily countdown

- Leave time = clock-in + **9h** (8h work + 1h lunch break).
- The lunch window (allowed 11:20–12:30) does not affect the math; the break
  is a fixed 1 hour regardless of when it is taken.
- Example: clock in 08:59 → leave at 17:59.

### Weekly overtime

- Required: **5h of overtime per week**.
- Week boundary: **Monday 00:00** local time (Asia/Seoul semantics; use system zone).
- Per day: `overtime = actual worked time (from Flex, net of break) − 8h`.
  Both signs count — working late adds, leaving early subtracts.
- Weekly counter = `Σ(daily overtime) − 5h`, displayed with sign:
  starts at `-5:00` Monday, moves toward `0:00`, goes positive (`+0:12`) past 5h.
- Today's overtime accrues live once the user passes their leave time;
  previous days come from Flex records.
- Example: Monday clock-in 09:01, leave time 18:01, stayed until 20:02 →
  2h01 overtime that day → weekly counter shows `-2:59`.

## Data Source: Flex (flex.team)

Flex has **no public API**. The app uses Flex's private API — the same XHR
endpoints the flex.team web app calls — authenticated with the user's own
session cookie.

### Authentication

- First launch (or on session expiry) opens a small window containing a
  `WKWebView` pointed at the real flex.team login page.
- After successful login, the app captures the session cookie(s) from the
  webview's cookie store and saves them in the **macOS Keychain**.
- API calls reuse the stored cookie. A `401`/redirect-to-login response
  invalidates the stored session and prompts re-login.

### API discovery (implementation step 0)

The private API endpoints and payload shapes are unknown until inspected.
First implementation task: log into flex.team, open the "my work record" page
(`/time-tracking/my-work-record`) with DevTools or browser automation, and
record which requests return clock-in/clock-out data for the current week.
FlexClient is built against those recorded fixtures.

**Risk:** the private API may change without notice. Mitigation: manual
fallback (below) keeps the app functional, and FlexClient is isolated so
fixes are localized.

## Architecture

Native Swift / SwiftUI app (no runtime dependencies), four units:

| Unit                    | Responsibility                                                                                                                    | Depends on                      |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| **FlexClient**          | Login webview, cookie capture, Keychain storage, fetch week's work records from the private API                                   | Keychain, URLSession, WKWebView |
| **WorkCalculator**      | Pure functions: `(clockIn, now) → timeLeft`, `([dayRecords], now) → weeklyOT`. No I/O.                                            | nothing                         |
| **MenuBarController**   | `MenuBarExtra` UI: smart single value, dropdown, 1s local tick, periodic refresh (~10 min) + refresh on wake-from-sleep           | FlexClient, WorkCalculator      |
| **Settings / Fallback** | Manual start-time entry when Flex is unavailable; user-editable constants (9h day, 5h/week, week start) persisted in UserDefaults | UserDefaults                    |

## Error Handling

| Condition                | Behavior                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------- |
| No session / expired     | Menu bar shows `⏳ —`; dropdown offers "Sign in to Flex" → opens login window                           |
| Network down             | Keep last-known data, mark stale in dropdown, countdown keeps ticking (needs only clock-in time)        |
| Not clocked in yet today | Menu bar shows `⏳ --:--` until a record appears (or manual entry)                                      |
| Flex API shape changed   | FlexClient errors are treated like network-down + a "Flex sync broken" notice; manual entry still works |

## Testing

- **WorkCalculator:** unit tests covering the user's canonical examples
  (08:59 → 17:59; Mon 09:01–20:02 → week `-2:59`), plus: leaving early
  (negative daily OT), Monday-reset boundary, work crossing midnight,
  not-yet-clocked-in, and passing leave time mid-tick.
- **FlexClient:** tests against recorded API fixtures from the discovery
  session (parse, session-expiry detection).
- **Manual smoke:** login flow, sleep/wake refresh, menu bar rendering.

## Out of Scope (YAGNI)

- Writing anything back to Flex (clock-in/out from the app).
- Notifications/alerts (could be a later addition).
- Multi-user, Windows/Linux, holiday/vacation calendars — vacation days are
  simply whatever Flex reports (a day with no record contributes 0 worked
  time and −8h overtime only if Flex marks it a workday; see Open Choices).

## Open Choices (deferred to implementation)

- Whether a Flex-marked vacation/holiday day counts as met-target (0 OT) —
  decide once we see how Flex represents such days in the API response.
- Exact refresh cadence and whether the OT display updates per-second or
  per-minute.
