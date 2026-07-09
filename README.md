# FlexTimer

A minimal macOS menu bar app for tracking work hours against your flex.team work schedule. Shows live clock-in time, overtime tracking, and manual fallback time entry when Flex is unavailable.

## What FlexTimer Shows

The menu bar displays a timer icon with one of the following states:

- **Counting**: `2:34` — currently clocked in, showing time remaining until your leave time (clock-in + 8h work + 1h break)
- **Overtime**: `OT -2:59` — after leave time, showing the weekly overtime counter. It resets to -5:00 every Monday at 00:00 (the 5h weekly overtime target) and updates live once you're past your daily leave time
    - Negative means you're still short of this week's 5h overtime target
    - Positive means you've exceeded the weekly target
    - Working past your daily leave time moves the counter up; leaving early moves it down
- **Not clocked in**: `--:--` — signed in but no active clock record
- **Signed out**: `—` — no Flex session or logged out

Click the menu item to open the dropdown:

- Shows today's work record (start time, end time if clocked out, overtime balance for the week)
- If no Flex record exists for today, offers a start-time picker (works offline)

## Installation

Build and install the app:

```bash
./scripts/bundle.sh
cp -r build/FlexTimer.app /Applications
```

Add to Login Items:

1. System Settings → General → Login Items
2. Click the + icon
3. Select `/Applications/FlexTimer.app`

## Authentication

FlexTimer uses an embedded login window to authenticate with flex.team. Your session is stored securely in the macOS Keychain:

- **Session cookies**: `AID` and `V2_WS_AID` are stored in Keychain and automatically included in API requests
- **User ID**: Automatically discovered from the `V2_CUSTOMER_INFO` cookie and stored in UserDefaults (key: `flexUserIdHash`); falls back to a hardcoded default if not found
- **Persistence**: You only need to log in once; the session persists across app restarts

## Customizing Work Hours

Override default work hours, break duration, and weekly overtime target using `defaults write` (these settings apply to the installed bundle):

```bash
# Daily work hours (default: 8.0)
defaults write com.perso.flextimer dailyWorkHours -float 9.0

# Break duration in minutes (default: 60)
defaults write com.perso.flextimer breakMinutes -float 45

# Weekly overtime target in hours (default: 5.0)
defaults write com.perso.flextimer weeklyOvertimeHours -float 6.0
```

**Note**: When running the app unbundled (`swift run`), UserDefaults uses a different domain than `com.perso.flextimer`, so these commands won't affect it. Use them against the installed app only.

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

This repository contains **real personal work records** in:

- `Tests/FlexTimerTests/Fixtures/*.json` — captured API responses with timestamps and work intervals
- `docs/flex-extract/` — personal time-tracking data

Before publishing this repo publicly, **remove or anonymize these files**.

## Building and Testing

```bash
# Run tests
swift test

# Build the app for development
swift run

# Build the release bundle
./scripts/bundle.sh
```

All 39 tests pass, covering work-record merging, overtime calculations, and display formatting.
