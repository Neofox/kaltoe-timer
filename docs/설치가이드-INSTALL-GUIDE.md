# 칼퇴타이머 v2.2.0 — 설치 가이드 / Install Guide

> 한국어 안내: `설치가이드-KR.md`

A tiny tray/menu-bar timer that watches your flex.team clock-in and counts
down to 칼퇴 — with lunch countdown, weekly overtime tracking, and warning
colours when it's time to leave.

Pick your OS below. Either way you'll sign in to Flex once with your normal
account inside the app; nothing is sent anywhere except to flex.team itself.

---

## What's new

**v2.2.0 — a progress ring for Linux**

- **The Linux tray shows progress at last, on both desktops.** On Fedora/KDE
  the icon's outline fills clockwise as the countdown runs down; on GNOME,
  where the countdown is text beside a small icon, that icon gains a ring
  around it instead — the same shape macOS draws for the same layout. Both use
  the Mac's colours and measure whatever the number beside them is counting:
  the morning fills toward lunch, the break toward going back, the afternoon
  toward leave time. Both step aside at the warning and critical stages, where
  the icon already turns orange or red.
- **macOS is unchanged** in this release apart from the version number.

**v2.1.0 — Korean menu, and a clearer ring**

- **The menu is in Korean.** 남은 시간, 퇴근 예정, 출근, 주간 초과근무, and the
  week strip's 월–금 — on the Linux tray as well as the Mac menu bar. The one
  line still in English is the shortened-day note (`Target 6:00 · family day`),
  which both share.
- **The ring now measures whatever the countdown is counting.** In the morning
  it fills toward lunch, during the break toward going back, and in the
  afternoon toward leave time — so a full ring always means the number beside
  it has run out. It used to measure the whole day, which left "10 minutes to
  lunch" sitting next to a barely-filled ring. The colour still travels across
  the whole day, so the morning still looks like the morning.
- **Week bars fill to the day's target.** The bars no longer keep empty space
  in reserve for overtime you may never work — a full bar means the day is
  done. When a day does run over, the whole strip rescales together so the five
  rows stay comparable.
- **A quieter menu.** 남은 시간 leads in larger type; days you haven't worked
  recede instead of matching the day you have; the last sync moved next to the
  re-sync button it belongs to; 라벨 스타일 is one line instead of two.
- **Thicker ring.** A slightly heavier stroke, so the colours read at menu bar
  size.

**v2.0.2 — appearance**

- **Bolder ring colours.** The progress colours through the working day were
  washed out at menu bar size, the midday green especially. They keep the same
  hues, just stronger.

**v2.0.1 — bug fix**

- **Fixed:** hourly leave booked under a policy that needs no approval was
  being ignored, leaving the day at its full target and showing `Leave at`
  later than it should be. It now shortens the day like any other leave.
  Leave still waiting for approval continues not to count.

**v2.0 — new features**

- **Redrawn menu bar label.** The countdown is now a *ring* closing around the
  icon or a *track* filling behind the label — your day's progress at a glance.
  Pick the style in the menu under **라벨 스타일** (label style).
- **Week strip.** The popover shows one row per weekday (Mon–Fri), each bar
  carrying its own overtime against that day's target.
- **Shortened days.** Approved time off and family day (last Friday of the
  month) now cut the day's target, and a caption under `Leave at` says why.
- **Weekend standdown.** On Saturday and Sunday the timer reads `주말!` and
  stops counting — weekends earn no overtime.
- Colours now follow your system's alert colours instead of tuned copies, so
  the label stays legible on an unfocused display.

---

## macOS — `칼퇴타이머-v2.2.0.zip`

Requires **macOS 26 or later** on **Apple Silicon** (M1 or newer). This build is
arm64-only — it will not launch on an Intel Mac.

1. Unzip, then move **칼퇴타이머.app** into **/Applications**.
2. The app is signed, but not notarized by Apple, so macOS quarantines it.
   Remove the flag once (right-click → Open does NOT work on our macOS
   version — use Terminal):

    ```
    xattr -dr com.apple.quarantine /Applications/칼퇴타이머.app
    ```

3. Launch it. A timer icon appears in the menu bar (no Dock icon).
4. Click the icon → **Sign in to Flex…** and log in with your Flex account.
5. When macOS asks to allow Keychain access, choose **항상 허용 (Always Allow)**
   — that's where your Flex session is stored. Because every build is signed
   with the same identity, it should only ask you this once, ever.
6. It adds itself to Login Items automatically on first launch (macOS shows a
   one-time notice) — nothing to do. Turn it off in System Settings → General
   → Login Items if you don't want that.

**Upgrading from v1.x?** Quit the old app first (menu bar icon → Quit), then
replace it in /Applications and re-run the `xattr` command above. If you still
have the very first release installed as `FlexTimer.app`, delete that too:

```
rm -rf /Applications/FlexTimer.app
```

Your saved Flex session carries over — you should not need to sign in again.

---

## Linux (Ubuntu / Fedora KDE) — `kaltoe-timer-linux-x86_64.tar.gz`

Requires Ubuntu 22.04+ (GNOME) or Fedora (KDE Plasma) — x86_64 (Intel/AMD,
not ARM).

1. Install the system dependencies (one-time):

    Ubuntu:

    ```
    sudo apt install python3-gi python3-gi-cairo gir1.2-ayatanaappindicator3-0.1 \
                     gir1.2-webkit2-4.1 libnotify-bin
    ```

    Fedora:

    ```
    sudo dnf install python3-gobject python3-cairo gtk3 gobject-introspection \
                     libayatana-appindicator-gtk3 webkit2gtk4.1 libnotify
    ```

2. Extract and install:

    ```
    tar xzf kaltoe-timer-linux-x86_64.tar.gz
    cd kaltoe-timer-linux
    ./install.sh
    ```

    This installs to `~/.local/share/kaltoe-timer/` and registers autostart —
    no sudo needed for this step. Upgrading is the same command; it overwrites
    the previous install and keeps your session.

3. Start it now (or just log out/in):

    ```
    ~/.local/share/kaltoe-timer/kaltoe-tray.py &
    ```

4. Click the tray icon → **Sign in to Flex…** and log in. Your session is
   saved to `~/.config/kaltoe-timer/session.json`, readable only by you.
5. Check your system timezone is correct (`timedatectl`) — all times follow
   the system clock.

A fuller README (what the phases mean, uninstall instructions,
troubleshooting) is inside the tarball as `README-linux.md`.

On KDE the countdown is drawn into the tray icon itself. The Linux tray keeps
the `BREAK` / `OT` word prefixes, because there it has no glyph to carry them.

---

## What you'll see

The label pairs a glyph with a figure, and fills as the day progresses:

| Label | Meaning |
|---|---|
| a sleep glyph, no figure | signed out — sign in from the menu |
| `--:--` | signed in, but not clocked in yet |
| `주말!` with a parasol | weekend — the timer is standing down |
| `1:20` with a fork | countdown to lunch leave (11:20) |
| `0:45` with a cup | on lunch break, counting down to 12:30 |
| `2:34` with a timer | time left until your leave time (clock-in + target) |
| `0:24` with a walking figure | 30 minutes or less to go |
| `자유!` | you have just hit your leave time |
| `+1:05` with a flame | past leave time — today's overtime, counting up |
| `+0:30` with a checkmark | clocked out; where the day landed against target |

Colour tracks the same phases: your accent colour while you're inside the
day's target, **orange** once you're past it, and **red** at the weekly
overtime cap or within 10 minutes of leave time — go home!

Click the icon for the full popover: `Leave at`, today's figure, and the week
strip. When your Flex session expires (every few weeks) you'll get a
notification — just sign in again from the menu.

## Troubleshooting

**"칼퇴타이머 cannot be opened", or `open` fails with error `-10810`**

The app is fine — macOS is resolving a stale copy. This happens when an older
version was replaced while still registered (or is still sitting in the Trash).
Check which bundles claim the app's ID, then re-register the real one:

```
mdfind "kMDItemCFBundleIdentifier == 'com.perso.flextimer'"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/칼퇴타이머.app
open /Applications/칼퇴타이머.app
```

If the first command lists anything other than `/Applications/칼퇴타이머.app`
— an old `FlexTimer.app`, a copy in Downloads, or one in the Trash — delete it,
empty the Trash, then re-run the `lsregister` line.

**Checking whether it's the app or macOS**

Run the executable directly. This bypasses macOS's launch machinery entirely:

```
/Applications/칼퇴타이머.app/Contents/MacOS/FlexTimer
```

If the menu bar icon appears, the app is healthy and the problem is the
registration above. If instead you see `Bad CPU type`, you're on an Intel Mac
and need a universal build — ask Jerome.

---

Questions/bugs → Jerome.
