# 칼퇴타이머 Linux (Ubuntu) Build — Design

2026-07-10

## Goal

One coworker runs Ubuntu and wants 칼퇴타이머. Ship a Linux build with a system
tray icon and an embedded flex.team login window, reusing the existing tested
business logic (work calculation, record parsing, display phases) so the Mac
and Linux versions never drift.

Naming: all new artifacts use **kaltoe** naming. The existing macOS module
(`FlexTimer`), bundle id (`com.perso.flextimer`), and Keychain service string
stay as-is so current users are not signed out. Files named after the
flex.team service (`FlexClient`, `FlexAPIConfig`, `FlexRecordParser`) keep
their names.

## Architecture

Two processes on Linux, mirroring the core/shell split that already exists in
the Mac app:

```
kaltoe-tray.py (Python + GTK)          kaltoe-core (Swift, headless)
┌─────────────────────────────┐  spawn ┌──────────────────────────────┐
│ AyatanaAppIndicator tray    │──────▶│ AppState-equivalent loop:     │
│ WebKitGTK login window      │ stdout│  - refresh Flex every 10 min  │
│ notify-send on session loss │◀──────│  - recompute every 1 s        │
│ menu: sign in/out, refresh, │ NDJSON│  - emit display state as JSON │
│       quit                  │       │    line on change + heartbeat │
└─────────────────────────────┘       └──────────────────────────────┘
                 │                                    │
                 └──── ~/.config/kaltoe-timer/session.json (0600) ────┘
                       {userIdHash, cookies: [...]}
```

## 1. Package restructure

Split `Package.swift` into three targets:

- **`KaltoeCore` (library, cross-platform)** — the portable files move here:
  `WorkCalculator`, `FlexRecordParser`, `DisplayState`, `Formatting`,
  `FlexAPIConfig`, `FlexClient`, `SettingsStore`, `HookRunner`, `CookieVault`.
    - Cookie/session storage splits by platform inside the core:
        - macOS: the existing Keychain implementation, unchanged service string
          (`com.perso.flextimer.session`).
        - Linux: JSON file `~/.config/kaltoe-timer/session.json` (created `0600`)
          holding `{userIdHash, cookies: [{name, value, domain, path, expires}]}`.
    - `FlexAPIConfig.userIdHash` reads from UserDefaults on macOS (unchanged)
      and from `session.json` on Linux.
    - Linux needs `import FoundationNetworking` conditionals for URLSession.
- **`FlexTimer` (macOS executable)** — the existing UI shell (`FlexTimerApp`,
  `AppDelegate`, `MenuBarView`, `MenuBarLabel`, `LoginWindowController`,
  `SessionNotifier`, `AppState`), now depending on `KaltoeCore`. No behavior
  change; bundle id and signing untouched.
- **`kaltoe-core` (executable, cross-platform)** — new ~100-line headless
  daemon replicating `AppState`'s loop without AppKit:
    - Load session from the platform store; refresh from Flex every 600 s;
      recompute display every 1 s.
    - Print one NDJSON line to stdout whenever the rendered display changes,
      plus a heartbeat line at least every 60 s:
      `{"text": "OT -0:59", "icon": "timer", "urgency": "critical",
  "hasSession": true, "lastSync": "2026-07-10T09:12:00Z",
  "syncError": null}`
        - `icon` is the semantic name the Mac app uses (`timer`, `fork.knife`,
          `cup.and.saucer`); the frontend maps it to shipped SVGs.
    - Exits when stdin closes (parent tray app quit).

Existing tests move to target `KaltoeCore` — business logic stays
single-source and tested.

## 2. Linux tray frontend — `linux/kaltoe-tray.py`

Python 3 + PyGObject, ~200 lines, no pip dependencies (system GI packages
only).

- Spawns `kaltoe-core` as a subprocess and reads stdout lines; restarts it
  after login/logout. Daemon lifecycle is tied to the tray app — no systemd.
- **Tray**: AyatanaAppIndicator3 item. Label = `text` from the JSON. Icon
  chosen from state + urgency — we ship SVGs for timer/fork/cup in default,
  orange (warning), and red (critical) variants, since AppIndicator labels
  cannot be colored (this replaces the Mac pill).
- **Login window**: GTK window with a WebKitGTK view loading
  `https://flex.team/sign-in`, mirroring `LoginWindowController`: on each
  page load, read the cookie store; when `AID` + `V2_WS_AID` exist for
  `flex.team`, extract `userIdHash` from the percent-encoded JSON in
  `V2_CUSTOMER_INFO`, write `session.json`, close the window, restart
  `kaltoe-core`.
- **Menu**: last-sync status line (disabled item), Sign in / Sign out,
  Refresh now (restarts core), Quit.
- **Session expiry**: when `hasSession` flips true→false, fire a desktop
  notification via `notify-send` prompting re-login.
- Out of scope for v1 (core supports them, no Linux UI): manual fallback
  start-time entry, clock-in/out hook scripts.

## 3. Build & distribution

- `scripts/build-linux.sh`: builds `kaltoe-core` inside a `swift:noble`
  Docker container for **x86_64** with `--static-swift-stdlib`, then produces
  `kaltoe-timer-linux-x86_64.tar.gz` containing:
    - `kaltoe-core` (binary), `kaltoe-tray.py`, `icons/` (9 SVGs),
      `install.sh`, `README-linux.md`.
- `install.sh`: copies files to `~/.local/share/kaltoe-timer/` and
  `~/.local/bin/`, writes an autostart `.desktop` entry to
  `~/.config/autostart/`.
- Coworker prerequisites (documented in `README-linux.md`):
  `sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1
gir1.2-webkit2gtk-4.1 libnotify-bin`.
  Stock Ubuntu GNOME also needs the AppIndicator support extension
  (`gnome-shell-extension-appindicator`), preinstalled on Ubuntu ≥ 22.04.

If the coworker turns out to be on ARM, only the Docker platform flag in
`build-linux.sh` changes.

## 4. Error handling

- Core: unchanged semantics from `AppState` — sync failure keeps last known
  data and sets `syncError`; expired session clears the stored cookies and
  flips `hasSession` false. Malformed `session.json` is treated as no
  session.
- Tray: if the core subprocess dies, show `--:--` with a tooltip error and
  offer "Restart" in the menu; if WebKitGTK is missing, fail at startup with
  an apt-install hint rather than a stack trace.

## 5. Testing

- `swift test` on macOS must pass unchanged after the target split.
- Run the same test suite once inside the `swift:noble` Docker container to
  surface Linux Foundation quirks (dates, UserDefaults, URLSession).
- `kaltoe-core` smoke test: run with a fixture `session.json`, assert NDJSON
  output shape.
- Tray script: manual smoke test on the coworker's Ubuntu machine (login,
  phases, urgency icons, quit/restart).
