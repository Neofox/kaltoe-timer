# 칼퇴타이머 for Linux (Ubuntu / Fedora KDE)

Tray timer for flex.team work hours — the Linux port of the macOS menu bar app.

## Requirements

Ubuntu 22.04+ (GNOME) or Fedora (KDE Plasma), x86_64.

Ubuntu:

    sudo apt install python3-gi python3-gi-cairo gir1.2-ayatanaappindicator3-0.1 \
                     gir1.2-webkit2-4.1 libnotify-bin

Fedora:

    sudo dnf install python3-gobject python3-cairo gtk3 gobject-introspection \
                     libayatana-appindicator-gtk3 webkit2gtk4.1 libnotify

On stock Ubuntu GNOME the AppIndicator extension
(`gnome-shell-extension-appindicator`) must be enabled — it ships enabled on
Ubuntu 22.04+. KDE Plasma needs nothing extra; the countdown is drawn into
the tray icon itself there (Plasma has no tray label). Set
`KALTOE_TRAY_MODE=label` or `=texticon` to override the automatic choice.

Make sure your system timezone is correct (`timedatectl`) — all times follow
the system clock.

## Install

    tar xzf kaltoe-timer-linux-x86_64.tar.gz
    cd kaltoe-timer-linux
    ./install.sh

The app autostarts at login. Start it immediately with:

    ~/.local/share/kaltoe-timer/kaltoe-tray.py &

## First run

Click the tray icon → **Sign in to Flex…** and log in with your normal Flex
credentials. The session is saved to `~/.config/kaltoe-timer/session.json`
(readable only by your user). When the session expires (a desktop
notification tells you), sign in again the same way.

## What the tray shows

Same phases as the Mac app: countdown to lunch (fork icon), break (cup),
countdown to leave time (timer), and today's overtime (`OT +1:00`) after leave
time. The week's total against the 12h cap is in the tray menu. The icon turns
orange within 30 minutes of leave time and while accruing overtime, and red
within 10 minutes of leave time or once you hit a company limit.

## Hooks

Run your own scripts when 칼퇴타이머 detects clock-in (출근) or clock-out
(퇴근). Drop executables at:

    ~/.config/kaltoe-timer/hooks/
    ├── on-clock-in
    └── on-clock-out

Both are optional; a missing or non-executable file is skipped. Remember
`chmod +x`.

Environment variables passed to the script:

- `KALTOE_EVENT` — `clock-in` or `clock-out`
- `KALTOE_CLOCK_IN` — clock-in time, ISO8601 (UTC)
- `KALTOE_CLOCK_OUT` — clock-out time, ISO8601 (UTC) (clock-out only)

Behavior:

- Each hook fires **at most once per event per day**, even across restarts.
  If the app starts after you already clocked in, the hook still fires —
  late, but once.
- Both events are detected via Flex sync (there is no manual start entry on
  Linux), so hooks can lag up to ~10 minutes behind the real clock-in/out.
- A clock-out that is only detected after midnight does not fire — the day
  it belonged to has already rolled over.
- Fire-and-forget: the app never waits on your script or reads its output.
  Backgrounded children keep running after the script exits.

Example — keep the machine awake while at work, lock the screen after
leaving:

`on-clock-in`:

    #!/bin/bash
    systemd-inhibit --what=idle --why="kaltoe: at work" sleep infinity &
    echo $! > /tmp/kaltoe-inhibit.pid

`on-clock-out`:

    #!/bin/bash
    [ -f /tmp/kaltoe-inhibit.pid ] && kill "$(cat /tmp/kaltoe-inhibit.pid)" 2>/dev/null
    rm -f /tmp/kaltoe-inhibit.pid
    loginctl lock-session

## Uninstall

    rm -rf ~/.local/share/kaltoe-timer ~/.config/kaltoe-timer \
           ~/.config/kaltoe-core.plist ~/.config/autostart/kaltoe-timer.desktop
