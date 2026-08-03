# 칼퇴타이머 (FlexTimer)

A minimal macOS menu bar app for tracking work hours against your flex.team work schedule, so you can 칼퇴 with confidence. Shows live clock-in time, overtime tracking, and manual fallback time entry when Flex is unavailable. (Internal module name: `FlexTimer`; bundle id `com.perso.flextimer`.)

## What 칼퇴타이머 Shows

The menu bar displays a progress fill, a glyph and a countdown, with one of the following phases:

- **To lunch**: `1:20` with a `fork.knife` icon — morning countdown to the lunch-leave moment (11:30 lunch start minus the 10-min early-leave allowance, i.e. counts down to 11:20)
- **On break**: `0:45` with a `cup.and.saucer` icon — during the 11:20–12:30 lunch window
- **Counting**: `2:34` with a `timer` icon — currently clocked in (outside the lunch window), showing time remaining until your leave time (clock-in + 8h work + 1h break)
- **Nearly 칼퇴**: `0:24` with a `figure.walk` icon — the last 30 minutes before leave time
- **자유!**: `자유!` with a `figure.walk.departure` icon — the first minute past your target. It occupies exactly the minute the overtime figure would render as `+0:00`, so it displaces nothing
- **Overtime**: `+1:00` with a `flame` icon — showing **today's** overtime: time worked beyond the 8h daily target. Overtime depends only on hours worked, never on when you work them — 09:00–19:00 and 07:00–17:00 are both 1h. The weekly total lives in the dropdown. On family day (last Friday of the month) the daily target is 6h, so the countdown targets leaving 2h early and doing so costs nothing.
  - Positive means you worked past today's target; negative means you clocked out short of it
  - Company limits: no more than 12h of overtime per week, and none past 22:00 — 칼퇴타이머 notifies you once when you cross either
- **Day settled**: `+1:00` with a `checkmark` icon — clocked out. The check means _settled_, not _target met_: a short day gets it too, beside a negative figure and a fill that visibly did not finish
- **Not clocked in**: `--:--` with a `timer` icon and an empty dashed fill — signed in but no active clock record
- **Signed out**: a `zzz` icon alone, with no number — no Flex session or logged out
- **Weekend**: `주말!` with a `beach.umbrella` icon — Saturday and Sunday. The timer stands down: no countdown, no target, and weekend hours earn no overtime, so the week strip's rows and the `Week OT` total always agree. A weekend clock-in is still recorded by Flex and still runs your clock hooks; 칼퇴타이머 just declines to count it.

The `BREAK` and `OT` word prefixes are gone from the menu bar label — the glyph carries the phase now. They remain on the **Linux tray**, which has no expressive glyph: on KDE that tray renders the countdown text alone, so `BREAK 0:45` is the only thing distinguishing a break from a countdown there.

**Progress fill**: the label carries a fill showing how far the day has run from clock-in to leave time — a closing **ring** around the glyph, or a **track** capsule filling behind the whole label. Pick either in the dropdown under `라벨 스타일`. The fill measures distance to leaving rather than work completed, so it keeps advancing through the lunch break instead of stalling for an hour, and it never runs backwards when the countdown beside it switches from counting-to-lunch to counting-to-leave.

**Colour through the day**: the fill interpolates blue → teal → green → amber across the working day, so you can read roughly where you are without focusing on the digits. Past your target it goes flat **orange**, and **red** once you hit a company limit — 12h of overtime this week, or still clocked in past 22:00. The orange is the system orange the week strip already uses in the dropdown — literally the same colour, not a near match — so the label and the strip always agree about whether you are over. The red is the label's alone; the week strip has no limit colour, showing the weekly cap as text (`Week OT 5:00 / 12:00`) instead.

A day with no record shows an empty dashed fill. A day you have clocked out of shows a grey fill stopped at whatever it reached.

The label is drawn as a pre-rendered image in every state, so macOS never greys it out on the menu bar of a display that doesn't have focus. That used to be an opt-in setting; it is now unconditional.

Click the menu item to open the dropdown:

- While on break, shows a "Back at" row with the time work resumes (end of the lunch window)
- Shows today's work record (start time, leave time, time left), then the week strip and the week's overtime against the 12h cap
- On a shortened day, adds a caption under `Leave at` naming what shortened it (see below)
- When today is a day off, reads "Day off" instead of "Not clocked in yet"
- If no Flex record exists for today, offers a start-time picker (works offline)

**Week strip**: one row per weekday, Monday to Friday, always five rows. Each row is a track — accent-coloured up to that day's work target, orange past it, with a 1pt notch marking the target and the hours worked printed on the right. So each row carries its own overtime rather than only feeding the total beneath it. On the day you're currently clocked in on the label turns accent-coloured and the accent fill is drawn at reduced strength, with a dashed outline continuing to its target. A day off reads `off` and a weekday with no record shows `·`; both render dimmed. All five bars share a fixed 10-hour scale so they're comparable, so a day beyond that saturates at a full bar — the exact figure is still printed beside it. The strip stays hidden until some day in the week has hours, and once shown it survives session expiry rather than blanking.

**Shortened days**: approved time off and family day (the last Friday of the month) both cut the day's target, which moves `Leave at` earlier with nothing on screen to say why. When either applies, a caption appears under `Leave at` — `Target 4:00 · family day, time off`. The lunch break also disappears once the target falls to half a day or less (policy: a 4h half-day has no lunch), so `Leave at` can move five hours earlier where the target dropped only four — the caption accounts for those four hours and never names the vanished break.

## Installation

Requires macOS 26 or later.

Build and install the app:

```bash
./scripts/bundle.sh
cp -r "build/칼퇴타이머.app" /Applications
# upgrading from v1? remove the old bundle first: rm -rf /Applications/FlexTimer.app
```

The app adds itself to Login Items on first launch (you'll see a one-time
macOS notice). To stop it starting automatically, turn it off under System
Settings → General → Login Items — the app respects that and won't re-add
itself.

### Code signing (one-time, recommended)

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

## Building and Testing

```bash
# Run tests
swift test

# Build the app for development
swift run

# Build the release bundle
./scripts/bundle.sh
```

The test suite passes on macOS, covering work-record merging, overtime calculations, and display formatting.

## Linux build

A Linux (Ubuntu) port ships as a tray app: the portable `KaltoeCore` logic is
compiled into a headless `kaltoe-core` daemon and fronted by
`linux/kaltoe-tray.py` (AppIndicator + WebKitGTK login). Build the
distributable with:

    ./scripts/build-linux.sh   # requires Docker; outputs build/kaltoe-timer-linux-x86_64.tar.gz

Install instructions for the recipient are in `linux/README-linux.md`.

### Tray icon render tests

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
