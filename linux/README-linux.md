# 칼퇴타이머 for Linux (Ubuntu)

Tray timer for flex.team work hours — the Linux port of the macOS menu bar app.

## Requirements

Ubuntu 22.04+ (GNOME) or Fedora (KDE Plasma), x86_64.

Ubuntu:

    sudo apt install python3-gi python3-gi-cairo gir1.2-ayatanaappindicator3-0.1 \
                     gir1.2-webkit2-4.1 libnotify-bin

Fedora:

    sudo dnf install python3-gobject python3-cairo gtk3 \
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
countdown to leave time (timer), and the weekly overtime counter (`OT -2:59`)
after leave time. The icon turns orange within 30 minutes of leave time and
red within 10 minutes or while overworking.

## Uninstall

    rm -rf ~/.local/share/kaltoe-timer ~/.config/kaltoe-timer \
           ~/.config/autostart/kaltoe-timer.desktop
