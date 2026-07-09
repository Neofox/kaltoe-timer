# 칼퇴타이머 (FlexTimer)

A minimal macOS menu bar app for tracking work hours against your flex.team work schedule, so you can 칼퇴 with confidence. Shows live clock-in time, overtime tracking, and manual fallback time entry when Flex is unavailable. (Internal module name: `FlexTimer`; bundle id `com.perso.flextimer`.)

## What 칼퇴타이머 Shows

The menu bar displays an icon plus text, with one of the following phases:

- **To lunch**: `1:20` with a `fork.knife` icon — morning countdown to the lunch-leave moment (11:30 lunch start minus the 10-min early-leave allowance, i.e. counts down to 11:20)
- **On break**: `BREAK 0:45` with a `cup.and.saucer` icon — during the 11:20–12:30 lunch window
- **Counting**: `2:34` with a `timer` icon — currently clocked in (outside the lunch window), showing time remaining until your leave time (clock-in + 8h work + 1h break)
- **Overtime**: `OT -2:59` with a `timer` icon — after leave time, showing the weekly overtime counter. It resets to -5:00 every Monday at 00:00 (the 5h weekly overtime target) and updates live once you're past your daily leave time. The requirement adjusts automatically: each holiday or vacation weekday reported by Flex deducts 1h, and a family-day week (last Friday of the month) deducts another 1h — e.g. a week with one public holiday plus family day requires 3h. On family day itself the daily target is 6h, so the countdown targets leaving 2h early and doing so costs nothing.
    - Negative means you're still short of this week's 5h overtime target
    - Positive means you've exceeded the weekly target
    - Working past your daily leave time moves the counter up; leaving early moves it down
    - Offline manual entries carry no holiday data, so fully-offline weeks show the unadjusted requirement
- **Not clocked in**: `--:--` — signed in but no active clock record
- **Signed out**: `—` — no Flex session or logged out

**Overwork warning colors**: once you're within 30 minutes of leave time (or working past it), the label switches from a plain icon+text to a colored capsule pill with white icon+text:

- **Orange pill** — ≤ 30 min before leave time
- **Red pill** — ≤ 10 min before leave time, or any time you're still clocked in past leave time

The label returns to the plain (non-pill) style after clock-out or outside these windows.

Click the menu item to open the dropdown:

- While on break, shows a "Back at" row with the time work resumes (end of the lunch window)
- Shows today's work record (start time, end time if clocked out, overtime balance for the week)
- If no Flex record exists for today, offers a start-time picker (works offline)

## Installation

Build and install the app:

```bash
./scripts/bundle.sh
cp -r "build/칼퇴타이머.app" /Applications
# upgrading from v1? remove the old bundle first: rm -rf /Applications/FlexTimer.app
```

Add to Login Items:

1. System Settings → General → Login Items
2. Click the + icon
3. Select `/Applications/칼퇴타이머.app`

## Authentication

FlexTimer uses an embedded login window to authenticate with flex.team. Your session is stored securely in the macOS Keychain:

- **Session cookies**: `AID` and `V2_WS_AID` are stored in Keychain and automatically included in API requests
- **User ID**: Automatically discovered from the `V2_CUSTOMER_INFO` cookie and stored in UserDefaults (key: `flexUserIdHash`); falls back to a hardcoded default if not found
- **Persistence**: You only need to log in once; the session persists across app restarts
- **Expiry notification**: when the session expires, the app posts a macOS notification ("Flex session expired — sign in again to keep tracking."); clicking it opens the sign-in window. Approve the notification permission prompt on first launch to get it.

## Customizing Work Hours

Override default work hours, break duration, and weekly overtime target using `defaults write` (these settings apply to the installed bundle):

```bash
# Daily work hours (default: 8.0)
defaults write com.perso.flextimer dailyWorkHours -float 9.0

# Break duration in minutes (default: 60)
defaults write com.perso.flextimer breakMinutes -float 45

# Weekly overtime target in hours (default: 5.0)
defaults write com.perso.flextimer weeklyOvertimeHours -float 6.0

# Lunch break start, in minutes from midnight (default: 690 = 11:30)
defaults write com.perso.flextimer lunchStartMinutes -float 690

# Lunch break end / work resumes, in minutes from midnight (default: 750 = 12:30)
defaults write com.perso.flextimer lunchEndMinutes -float 750

# Allowed early departure to lunch, in minutes (default: 10)
defaults write com.perso.flextimer lunchEarlyLeaveMinutes -float 10

defaults write com.perso.flextimer dayOffDeductionHours -float 1 # weekly-required reduction per holiday/vacation day
defaults write com.perso.flextimer familyDayEarlyLeaveHours -float 2 # family-day early leave; 0 disables family day
defaults write com.perso.flextimer familyDayDeductionHours -float 1 # weekly-required reduction on family-day weeks
```

**Note**: When running the app unbundled (`swift run`), UserDefaults uses a different domain than `com.perso.flextimer`, so these commands won't affect it. Use them against the installed app only.

## Hooks

Run your own scripts when 칼퇴타이머 detects 출근 (clock-in) or 퇴근 (clock-out). Drop executables at:

```
~/Library/Application Support/칼퇴타이머/hooks/
├── on-clock-in
└── on-clock-out
```

Both are optional; a missing or non-executable file is skipped. Remember `chmod +x`.

Scripts receive environment variables:

- `KALTOE_EVENT` — `clock-in` or `clock-out`
- `KALTOE_CLOCK_IN` — clock-in time, ISO8601 (UTC)
- `KALTOE_CLOCK_OUT` — clock-out time, ISO8601 (UTC) (clock-out only)

Semantics:

- Each hook fires **at most once per event per day**, even across app restarts. If the app launches after you already clocked in (e.g. Mac booted late), the hook still fires — late, but once.
- 퇴근 is detected via Flex sync, so the clock-out hook can lag up to ~10 minutes. Syncs happen on app launch, every 10 minutes, and on wake from sleep.
- A 퇴근 that's only detected after midnight (e.g. you clocked out just before midnight and the next sync lands after, or the Mac was asleep until the next day) will not fire the clock-out hook — the day it belonged to has already rolled over.
- Hooks are fire-and-forget: the app never waits on your script or reads its output. Backgrounded children (`caffeinate &`) keep running after the script exits.

Example — keep the Mac awake while at work, lock the screen and clean up after leaving:

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
pmset displaysleepnow   # lock the screen (with the default "require password immediately")
```

The morning `caffeinate -d` conveniently guarantees the Mac is still awake when clock-out is detected. `pmset displaysleepnow` needs no special permissions.

## Manual Time Entry

When there's no Flex record for today (network issue, API change, or day not yet started in Flex), you can manually enter a start time:

1. Click the menu item
2. If the dropdown shows "No record for today", tap the start-time picker
3. Select your clock-in time
4. The timer will count from that time (works offline)

This fallback allows you to keep tracking even if Flex is temporarily unavailable or your session expires.

## Daily and Weekly Calculations

- **Leave time** = clock-in + `dailyWorkHours` + `breakMinutes` / 60 hours
- **Daily overtime** = (clock-out time) − (leave time), or current elapsed − (leave time) if still clocked in
- **Weekly overtime** = sum of daily overtime for all worked days in the current week (Monday 00:00 reset)
- Unworked days (weekends, holidays, or days not yet started) contribute 0 to the weekly total

## Data

FlexTimer fetches two endpoints from the flex.team API:

- **`/api/v3/time-tracking/users/{userIdHash}/work-schedules`** — completed work blocks and breaks for past days
- **`/api/v2/time-tracking/work-clock/users`** — live/ongoing clock records for today

See `docs/flex-api.md` for endpoint details, response schema, and how to re-capture them if flex.team changes their API.

## Privacy Note

The repository contains **no personal data**: test fixtures under
`Tests/FlexTimerTests/Fixtures/` are synthetic (real API shape, fabricated
times, fake user id), and no user identifier is hardcoded — each user's
`userIdHash` is auto-discovered from their own Flex session at sign-in.
(`docs/flex-extract/` is a local, untracked scratch area.)

## Building and Testing

```bash
# Run tests
swift test

# Build the app for development
swift run

# Build the release bundle
./scripts/bundle.sh
```

All 58 tests pass, covering work-record merging, overtime calculations, and display formatting.
