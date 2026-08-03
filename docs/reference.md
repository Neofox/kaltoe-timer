# Reference

Detail lifted out of the README so that stays a tour rather than a manual.
Nothing here has been rewritten — only relocated.

## Code signing (one-time, recommended)

Without this, macOS treats every rebuild as a new app and re-asks for keychain
access to your Flex session after each upgrade ("칼퇴타이머 wants to use
'com.perso.flextimer.session'"). Create a stable self-signed identity once and
`bundle.sh` picks it up automatically:

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `kaltoe-dev` · Identity Type: **Self-Signed Root** · Certificate Type: **Code Signing** → Create
3. Rebuild and reinstall. On the app's next keychain prompt, click **항상 허용 (Always Allow)** — with a stable identity it now sticks across all future rebuilds.

## Authentication

FlexTimer uses an embedded login window to authenticate with flex.team. Your session is stored securely in the macOS Keychain:

- **Session cookies**: `AID` and `V2_WS_AID` are stored in Keychain and automatically included in API requests
- **User ID**: Automatically discovered from the `V2_CUSTOMER_INFO` cookie and stored in UserDefaults (key: `flexUserIdHash`); falls back to a hardcoded default if not found
- **Persistence**: You only need to log in once; the session persists across app restarts
- **Expiry notification**: when the session expires, the app posts a macOS notification ("Flex session expired — sign in again to keep tracking."); clicking it opens the sign-in window. Approve the notification permission prompt on first launch to get it.

## Customizing Work Hours

Override default work hours, break duration, and the overtime limits using `defaults write` (these settings apply to the installed bundle):

```bash
# Daily work hours (default: 8.0)
defaults write com.perso.flextimer dailyWorkHours -float 9.0

# Break duration in minutes (default: 60)
defaults write com.perso.flextimer breakMinutes -float 45

# Maximum overtime allowed per week, in hours (default: 12.0)
defaults write com.perso.flextimer weeklyOvertimeCapHours -float 12.0

# No overtime past this time, in minutes from midnight (default: 1320 = 22:00)
defaults write com.perso.flextimer overtimeCutoffMinutes -float 1320

# Lunch break start, in minutes from midnight (default: 690 = 11:30)
defaults write com.perso.flextimer lunchStartMinutes -float 690

# Lunch break end / work resumes, in minutes from midnight (default: 750 = 12:30)
defaults write com.perso.flextimer lunchEndMinutes -float 750

# Allowed early departure to lunch, in minutes (default: 10)
defaults write com.perso.flextimer lunchEarlyLeaveMinutes -float 10

defaults write com.perso.flextimer familyDayEarlyLeaveHours -float 2 # family-day early leave; 0 disables family day
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
- 퇴근 is detected via Flex sync, so the clock-out hook can lag up to ~10 minutes. Syncs happen on app launch, every 10 minutes, on wake from sleep, and on screen unlock.
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
- **Daily overtime** = (clock-out time) − (leave time), or current elapsed − (leave time) if still clocked in; negative if you clocked out short of the target
- **Weekly overtime** = sum of daily overtime for all worked days in the current week, **each day floored at 0** (Monday 00:00 reset) — a short day contributes nothing and never offsets a long one
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

## Tray icon render tests

The tray icon is a PNG this code draws with Cairo, so short of a Plasma panel
the only way to check it is to render it. `--render-test` is that seam, and it
now takes the progress border's fill and colour as optional trailing arguments:

    rm -rf build/render-test && mkdir -p build/render-test
    docker run --rm --platform linux/amd64 -v "$PWD/linux":/app \
      -v "$PWD/build/render-test":/out -w /app fedora:latest \
      bash -c 'dnf install -y python3-gobject python3-cairo gtk3 \
          libayatana-appindicator-gtk3 webkit2gtk4.1 libnotify \
          gobject-introspection >/dev/null 2>&1
        python3 kaltoe-tray.py --render-test /out/normal.png "2:34" normal
        python3 kaltoe-tray.py --render-test /out/break.png "BREAK 0:45" normal
        python3 kaltoe-tray.py --render-test /out/critical.png "OT -0:59" critical
        python3 kaltoe-tray.py --render-test /out/border.png "1:25" normal 0.18 "#258ef7"'

`--render-ring <out.png> <icon-name> <fill> <#rrggbb>` does the same for label
mode's ringed glyph, which is what GNOME shows:

    python3 kaltoe-tray.py --render-ring /out/ring.png kaltoe-fork 0.42 "#51cc29"

Then look at them — **resampled to about 22px, not at their native 64**. The
panel scales them down, and text that is comfortable at full size can be mush
there; that resampled view is what chose the border's padding, and judging at
64 would have chosen differently.

Use the real renderer for this. A stand-in built on Cairo's toy text API reads
differently enough from Pango to reverse a conclusion, which it once did.

Geometry has its own GTK-free tests, runnable anywhere:

    python3 linux/test_kaltoe_border.py   # progress-border path arithmetic
    python3 linux/test_kaltoe_rows.py     # week row label formatting
