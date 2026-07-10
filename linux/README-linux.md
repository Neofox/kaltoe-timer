# 칼퇴타이머 for Linux (Ubuntu)

Tray timer for flex.team work hours — the Linux port of the macOS menu bar app.

## Requirements

Ubuntu 22.04+ with GNOME (or any desktop with AppIndicator/StatusNotifier
support). Install the system dependencies:

    sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1 \
                     gir1.2-webkit2-4.1 libnotify-bin

On stock Ubuntu GNOME the AppIndicator extension
(`gnome-shell-extension-appindicator`) must be enabled — it ships enabled on
Ubuntu 22.04+.

Make sure your system timezone is set correctly (check with `timedatectl`) —
all times (lunch, break, leave time, overtime) follow the system timezone.

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
countdown to leave time (timer), and the weekly overtime counter (`OT -2:59`)
after leave time. The icon turns orange within 30 minutes of leave time and
red within 10 minutes or while overworking.

## Uninstall

    rm -rf ~/.local/share/kaltoe-timer ~/.config/kaltoe-timer \
           ~/.config/autostart/kaltoe-timer.desktop
