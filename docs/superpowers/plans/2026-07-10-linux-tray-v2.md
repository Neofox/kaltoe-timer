# Linux Tray v2 Implementation Plan (Fedora KDE + Menu Detail Rows)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support the Fedora KDE coworker (verified binary, dnf docs, countdown rendered into the tray icon since Plasma shows no label) and add the Mac dropdown's Started / Leave at / Time left / Week OT rows to the Linux tray menu.

**Architecture:** `StatusLine` gains three optional fields the daemon populates from `WorkCalculator`; the tray adds insensitive menu rows (Time left ticks locally from `leaveAt`) and a KDE-only text-in-icon renderer (cairo+PangoCairo PNG swapped through the icon-theme-path cache-busting trick). Fedora compatibility is proven in a container, never on the coworker's machine.

**Tech Stack:** Swift (KaltoeCore/KaltoeDaemon), Python 3 + PyGObject + cairo/PangoCairo, Docker (`swift:6.1-noble` build, `fedora:latest` verification).

**Spec:** `docs/superpowers/specs/2026-07-10-fedora-kde-design.md`

## Global Constraints

- NDJSON contract stays backward compatible: new fields are optional and OMITTED when nil (`started`, `leaveAt` ISO8601; `weekOvertime` integer seconds rounded to the whole minute, truncating toward zero to match `Formatting.signedHM`).
- `started`/`leaveAt` present only when session exists AND today has a record; `weekOvertime` present whenever session exists.
- Tray mode: `KALTOE_TRAY_MODE=label|texticon` env override; default `texticon` iff `"KDE" in XDG_CURRENT_DESKTOP`, else `label`. GNOME (label-mode) behavior byte-identical to today except the new menu rows.
- Text-icon colors: normal = `#dfdfdf` text, transparent bg; warning/critical = white text on `#ff9500`/`#ff3b30` capsule. Height 22 px, width fits text.
- No new pip deps; cairo/PangoCairo come from the PyGObject stack (`python3-gi-cairo` on Ubuntu, `python3-cairo` on Fedora).
- All times displayed in the tray are converted to local time (existing `_local_sync_label` pattern).
- `swift test` green at every commit (118 + new StatusLine tests); `python3 -m py_compile linux/kaltoe-tray.py` green at every tray commit.
- Do not run the `kaltoe-core` binary on macOS (Keychain prompt).

---

### Task 1: StatusLine detail fields + daemon population (Swift, TDD)

**Files:**

- Modify: `Sources/KaltoeCore/StatusLine.swift`
- Modify: `Sources/KaltoeDaemon/HeadlessState.swift` (the `status(now:)` method)
- Test: `Tests/KaltoeCoreTests/StatusLineTests.swift`

**Interfaces:**

- Consumes: `WorkCalculator.timeOff(on:in:)`, `WorkCalculator.leaveTime(clockIn:rules:timeOff:)`, `WorkCalculator.weeklyOvertime(records:dayOffs:timeOff:now:rules:)` — all public since the package split; `WeekData.todayRecord/weekIncludingManual`.
- Produces: `StatusLine.init(display:hasSession:lastSync:syncError:started:leaveAt:weekOvertime:)` where the last three default to `nil` (existing call sites compile unchanged); JSON keys `started`, `leaveAt` (ISO8601 strings), `weekOvertime` (Int seconds). Task 2's tray parsing relies on exactly these key names.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KaltoeCoreTests/StatusLineTests.swift`:

```swift
    func testDetailFieldsOmittedByDefault() throws {
        let line = StatusLine(display: MenuDisplay(state: .noSession, urgency: .normal),
                              hasSession: false, lastSync: nil, syncError: nil)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("started"), json)
        XCTAssertFalse(json.contains("leaveAt"), json)
        XCTAssertFalse(json.contains("weekOvertime"), json)
    }

    func testDetailFieldsEncodeWhenSet() throws {
        let line = StatusLine(display: MenuDisplay(state: .counting(timeLeft: 3600), urgency: .normal),
                              hasSession: true, lastSync: nil, syncError: nil,
                              started: Date(timeIntervalSince1970: 0),
                              leaveAt: Date(timeIntervalSince1970: 9 * 3600),
                              weekOvertime: 240)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""started":"1970-01-01T00:00:00Z""#), json)
        XCTAssertTrue(json.contains(#""leaveAt":"1970-01-01T09:00:00Z""#), json)
        XCTAssertTrue(json.contains(#""weekOvertime":240"#), json)
    }

    func testWeekOvertimeRoundsToWholeMinutesTowardZero() {
        func line(_ ot: TimeInterval) -> StatusLine {
            StatusLine(display: MenuDisplay(state: .notClockedIn, urgency: .normal),
                       hasSession: true, lastSync: nil, syncError: nil,
                       started: nil, leaveAt: nil, weekOvertime: ot)
        }
        XCTAssertEqual(line(250).weekOvertime, 240)    // 4m10s -> 4m
        XCTAssertEqual(line(-250).weekOvertime, -240)  // -4m10s -> -4m (toward zero, matches signedHM)
        XCTAssertEqual(line(0).weekOvertime, 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StatusLineTests`
Expected: FAIL to compile — no `started:` parameter in the initializer.

- [ ] **Step 3: Extend StatusLine**

In `Sources/KaltoeCore/StatusLine.swift`, add three stored properties after `syncError` and replace the initializer:

```swift
    public var syncError: String?
    /// Detail rows for the tray menu (Mac-dropdown parity). Omitted when
    /// signed out / not clocked in.
    public var started: Date?
    public var leaveAt: Date?
    /// Weekly overtime in seconds, truncated to the whole minute so the
    /// daemon's change-driven emission stays minute-cadenced.
    public var weekOvertime: Int?

    public init(display: MenuDisplay, hasSession: Bool, lastSync: Date?, syncError: String?,
                started: Date? = nil, leaveAt: Date? = nil, weekOvertime: TimeInterval? = nil) {
        self.text = display.state.menuBarText
        self.icon = display.state.iconName
        self.urgency = display.urgency.rawValue
        self.hasSession = hasSession
        self.lastSync = lastSync
        self.syncError = syncError
        self.started = started
        self.leaveAt = leaveAt
        self.weekOvertime = weekOvertime.map { Int($0 / 60) * 60 }
    }
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter StatusLineTests`
Expected: PASS (including the pre-existing golden-string test — omitted nils leave it untouched).

- [ ] **Step 5: Populate from the daemon**

Replace `status(now:)` in `Sources/KaltoeDaemon/HeadlessState.swift` (mirrors what the Mac `MenuBarView` computes for its rows):

```swift
    func status(now: Date) -> StatusLine {
        let today = weekData.todayRecord(now: now)
        let week = weekData.weekIncludingManual(now: now)
        let rules = SettingsStore.rules
        let display = DisplayState.computeDisplay(hasSession: hasSession,
                                                  today: today,
                                                  week: week,
                                                  dayOffs: weekData.dayOffDates,
                                                  timeOff: weekData.timeOff,
                                                  now: now, rules: rules)
        var leaveAt: Date?
        if hasSession, let today {
            let off = WorkCalculator.timeOff(on: today.clockIn, in: weekData.timeOff)
            leaveAt = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules, timeOff: off)
        }
        let weekOvertime: TimeInterval? = hasSession
            ? WorkCalculator.weeklyOvertime(records: week, dayOffs: weekData.dayOffDates,
                                            timeOff: weekData.timeOff, now: now, rules: rules)
            : nil
        return StatusLine(display: display, hasSession: hasSession,
                          lastSync: lastSync, syncError: syncError,
                          started: hasSession ? today?.clockIn : nil,
                          leaveAt: leaveAt, weekOvertime: weekOvertime)
    }
```

Note: `HeadlessState` has no unit-test target; this mapping is covered by the StatusLine tests plus the container smoke test (no-session case) and mirrors `MenuBarView`'s calls one-for-one — say so in the commit if asked, don't add a new test target for it.

- [ ] **Step 6: Full suite + commit**

Run: `swift build && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 121 tests, with 0 failures`.

```bash
git add Sources/KaltoeCore/StatusLine.swift Sources/KaltoeDaemon/HeadlessState.swift Tests/KaltoeCoreTests/StatusLineTests.swift
git commit -m "feat: StatusLine carries started/leaveAt/weekOvertime detail fields"
```

---

### Task 2: Tray menu detail rows + ticking Time left

**Files:**

- Modify: `linux/kaltoe-tray.py`

**Interfaces:**

- Consumes: NDJSON keys `started`/`leaveAt` (ISO8601 with `Z`), `weekOvertime` (Int seconds) from Task 1.
- Produces: `self.leave_at_dt` (aware `datetime` or None) — Task 3 must not touch it.

- [ ] **Step 1: Add parsing/formatting helpers**

Next to the existing `_local_sync_label` staticmethod, add:

```python
    @staticmethod
    def _parse_iso(iso_utc):
        try:
            return datetime.fromisoformat(iso_utc.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            return None

    @staticmethod
    def _local_hhmm(dt):
        return dt.astimezone().strftime("%H:%M")

    @staticmethod
    def _signed_hm(seconds):
        minutes = abs(int(seconds)) // 60
        sign = "-" if seconds < 0 and minutes > 0 else "+"
        return f"{sign}{minutes // 60}:{minutes % 60:02d}"
```

(`_signed_hm` mirrors `Formatting.signedHM`: zero renders `+0:00`.)

- [ ] **Step 2: Add the info rows to the menu**

In `_build_menu`, insert BEFORE the `self.status_item` block (the rows sit above "Synced …", matching the Mac):

```python
        self.started_item = Gtk.MenuItem(label="")
        self.started_item.set_sensitive(False)
        menu.append(self.started_item)

        self.leave_item = Gtk.MenuItem(label="")
        self.leave_item.set_sensitive(False)
        menu.append(self.leave_item)

        self.timeleft_item = Gtk.MenuItem(label="")
        self.timeleft_item.set_sensitive(False)
        menu.append(self.timeleft_item)

        self.ot_item = Gtk.MenuItem(label="")
        self.ot_item.set_sensitive(False)
        menu.append(self.ot_item)

        menu.append(Gtk.SeparatorMenuItem())
```

After `menu.show_all()` (next to `self.restart_item.hide()`), hide them until data arrives:

```python
        for item in (self.started_item, self.leave_item, self.timeleft_item, self.ot_item):
            item.hide()
```

- [ ] **Step 3: Populate rows in apply_status**

In `__init__`, add `self.leave_at_dt = None` next to the other state, and start the tick timer after `self.start_core()`:

```python
        GLib.timeout_add_seconds(1, self._tick)
```

In `apply_status`, after the `self.status_item.set_label(...)` line, add:

```python
        started = self._parse_iso(status.get("started"))
        self.leave_at_dt = self._parse_iso(status.get("leaveAt"))
        week_ot = status.get("weekOvertime")

        self.started_item.set_visible(started is not None)
        if started:
            self.started_item.set_label(f"Started {self._local_hhmm(started)}")
        self.leave_item.set_visible(self.leave_at_dt is not None)
        if self.leave_at_dt:
            self.leave_item.set_label(f"Leave at {self._local_hhmm(self.leave_at_dt)}")
        self.timeleft_item.set_visible(self.leave_at_dt is not None)
        self.ot_item.set_visible(week_ot is not None)
        if week_ot is not None:
            self.ot_item.set_label(f"Week OT {self._signed_hm(week_ot)}")
        self._tick()
```

- [ ] **Step 4: Add the tick method**

New method after `apply_status` (leave-time semantics live in the daemon; this is pure subtraction):

```python
    def _tick(self):
        if self.leave_at_dt:
            left = max(0, int((self.leave_at_dt - datetime.now().astimezone()).total_seconds()))
            self.timeleft_item.set_label(
                f"Time left {left // 3600}:{(left % 3600) // 60:02d}:{left % 60:02d}")
        return True
```

- [ ] **Step 5: Verify + commit**

Run: `python3 -m py_compile linux/kaltoe-tray.py && echo OK`
Expected: `OK`

```bash
git add linux/kaltoe-tray.py
git commit -m "feat: tray menu shows Started/Leave at/Time left/Week OT rows"
```

---

### Task 3: KDE text-in-icon mode + --render-test

**Files:**

- Modify: `linux/kaltoe-tray.py`

**Interfaces:**

- Consumes: existing `apply_status` text/icon/urgency handling and `on_core_dead`.
- Produces: module-level `render_text_icon(text, urgency, out_path)`; CLI `kaltoe-tray.py --render-test <out.png> <text> <urgency>` (used by Task 5's container verification).

- [ ] **Step 1: Imports and mode constant**

Top of file: add `import sys` and `import tempfile` to the stdlib imports. After the existing `gi.require_version` block, add Pango requirements and imports (cairo comes from pycairo, imported plainly):

```python
import cairo

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo
```

(Fold the two new `require_version` calls into the existing try/except that prints the install hint.)

Next to the other module constants:

```python
# Plasma's StatusNotifierItem tray has no label field, so on KDE the
# countdown text is rendered into the icon itself.
TRAY_MODE = os.environ.get("KALTOE_TRAY_MODE") or (
    "texticon" if "KDE" in os.environ.get("XDG_CURRENT_DESKTOP", "") else "label")
```

- [ ] **Step 2: The renderer (module-level, before TrayApp)**

```python
ICON_HEIGHT = 22
PILL_COLORS = {"warning": (1.0, 0.584, 0.0), "critical": (1.0, 0.231, 0.188)}


def render_text_icon(text, urgency, out_path):
    """Render the tray label into a PNG: plain light-gray text normally,
    white-on-orange/red capsule at warning/critical (the Mac pill)."""
    # Measure first with a throwaway surface.
    probe = cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1)
    layout = PangoCairo.create_layout(cairo.Context(probe))
    layout.set_font_description(Pango.FontDescription("Sans Bold 11"))
    layout.set_text(text, -1)
    text_w, text_h = layout.get_pixel_size()

    pad = 6 if urgency in PILL_COLORS else 2
    width = text_w + 2 * pad
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, ICON_HEIGHT)
    cr = cairo.Context(surface)

    if urgency in PILL_COLORS:
        r, g, b = PILL_COLORS[urgency]
        radius = ICON_HEIGHT / 2 - 1
        cr.set_source_rgb(r, g, b)
        cr.arc(radius + 1, ICON_HEIGHT / 2, radius, 0.5 * 3.14159, 1.5 * 3.14159)
        cr.arc(width - radius - 1, ICON_HEIGHT / 2, radius, 1.5 * 3.14159, 0.5 * 3.14159)
        cr.close_path()
        cr.fill()
        cr.set_source_rgb(1, 1, 1)
    else:
        cr.set_source_rgb(0.875, 0.875, 0.875)  # dfdfdf, matches static icons

    layout = PangoCairo.create_layout(cr)
    layout.set_font_description(Pango.FontDescription("Sans Bold 11"))
    layout.set_text(text, -1)
    cr.move_to(pad, (ICON_HEIGHT - text_h) / 2)
    PangoCairo.show_layout(cr, layout)
    surface.write_to_png(out_path)
```

- [ ] **Step 3: Wire the mode into TrayApp**

In `__init__`, after `self.indicator.set_icon_theme_path(ICON_DIR)`:

```python
        self.texticon = TRAY_MODE == "texticon"
        self.icon_flip = False
        if self.texticon:
            self.icon_temp = tempfile.mkdtemp(prefix="kaltoe-tray-")
            self.indicator.set_icon_theme_path(self.icon_temp)
```

Guard the initial `self.indicator.set_label("--:--", LABEL_GUIDE)` with `if not self.texticon:`.

In `apply_status`, replace the two lines

```python
        self.indicator.set_label(text, LABEL_GUIDE)
        self.indicator.set_icon_full(icon, text)
```

with

```python
        if self.texticon:
            self._set_text_icon(text, urgency)
        else:
            self.indicator.set_label(text, LABEL_GUIDE)
            self.indicator.set_icon_full(icon, text)
```

New method (near `apply_status`):

```python
    def _set_text_icon(self, text, urgency):
        # AppIndicator caches icons by name — alternate names to force reload.
        self.icon_flip = not self.icon_flip
        name = "kaltoe-live-a" if self.icon_flip else "kaltoe-live-b"
        render_text_icon(text, urgency, os.path.join(self.icon_temp, name + ".png"))
        self.indicator.set_icon_full(name, text)
```

In `on_core_dead`, replace the two indicator lines with the mode-aware version:

```python
        if self.texticon:
            self._set_text_icon("--:--", "normal")
        else:
            self.indicator.set_label("--:--", LABEL_GUIDE)
            self.indicator.set_icon_full("kaltoe-timer", "core stopped")
```

- [ ] **Step 4: --render-test CLI seam**

Replace the `main()` body's start with:

```python
def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "--render-test":
        render_text_icon(sys.argv[3], sys.argv[4], sys.argv[2])
        print(f"wrote {sys.argv[2]}")
        return
    if not os.path.exists(CORE_BIN):
        raise SystemExit(f"kaltoe-core binary not found next to this script: {CORE_BIN}\n"
                         "Run from the installed directory (see README-linux.md).")
    TrayApp()
    Gtk.main()
```

- [ ] **Step 5: Verify + commit**

Run: `python3 -m py_compile linux/kaltoe-tray.py && echo OK`
Expected: `OK` (rendering itself is exercised in Task 5's Fedora container — no cairo on this Mac).

```bash
git add linux/kaltoe-tray.py
git commit -m "feat: KDE text-in-icon tray mode with --render-test seam"
```

---

### Task 4: Docs

**Files:**

- Modify: `linux/README-linux.md` (Requirements section)
- Modify: `build/설치가이드-INSTALL-GUIDE.md` (untracked — edit, do NOT git add)

- [ ] **Step 1: README-linux Requirements section**

Replace the Requirements section's install instructions with distro variants (keep the surrounding prose; exact dnf names may be corrected by Task 5 — this task writes the expected set):

```markdown
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
```

- [ ] **Step 2: Share guide**

In `build/설치가이드-INSTALL-GUIDE.md`, retitle the "## Ubuntu — …" section to `## Linux (Ubuntu / Fedora KDE) — kaltoe-timer-linux-x86_64.tar.gz`, and replace its step 1 with both install commands from Step 1 above (apt for Ubuntu, dnf for Fedora). Add one sentence at the end of the section: "On KDE the countdown is drawn into the tray icon itself."

- [ ] **Step 3: Commit**

```bash
git add linux/README-linux.md
git commit -m "docs: Fedora/KDE requirements and tray-mode notes"
```

---

### Task 5: Rebuild tarball + Fedora container verification

**Files:**

- Modify (only if Fedora package names differ): `linux/README-linux.md`, `build/설치가이드-INSTALL-GUIDE.md`

- [ ] **Step 1: Rebuild the tarball**

Run: `./scripts/build-linux.sh`
Expected: `Built build/kaltoe-timer-linux-x86_64.tar.gz` (contains the Task 1 daemon and Task 2/3 tray).

- [ ] **Step 2: Binary smoke on Fedora**

```bash
docker run --rm --platform linux/amd64 -v "$PWD/build/kaltoe-timer-linux":/app -w /app \
  -e KALTOE_CONFIG_DIR=/tmp/kaltoe-none fedora:latest \
  bash -c 'sleep 3 | ./kaltoe-core | head -n 1'
```

Expected (exact): `{"hasSession":false,"icon":"timer","text":"—","urgency":"normal"}`
If it fails with a glibc version error, STOP and report — that triggers the out-of-scope musl fallback decision.

- [ ] **Step 3: Dependency + import check on Fedora**

```bash
docker run --rm --platform linux/amd64 -v "$PWD/build/kaltoe-timer-linux":/app -w /app fedora:latest \
  bash -c 'dnf install -y python3-gobject python3-cairo gtk3 libayatana-appindicator-gtk3 webkit2gtk4.1 libnotify >/dev/null 2>&1; \
    python3 -c "
import gi, cairo
gi.require_version(\"Gtk\", \"3.0\")
gi.require_version(\"WebKit2\", \"4.1\")
gi.require_version(\"Pango\", \"1.0\")
gi.require_version(\"PangoCairo\", \"1.0\")
try:
    gi.require_version(\"AyatanaAppIndicator3\", \"0.1\")
except ValueError:
    gi.require_version(\"AppIndicator3\", \"0.1\")
print(\"IMPORTS OK\")"'
```

Expected: `IMPORTS OK`. If a package name is wrong, find the right one (`dnf search appindicator` etc.), fix the README/guide lists from Task 4, and note the correction.

- [ ] **Step 4: Render-test PNGs**

```bash
mkdir -p build/render-test
docker run --rm --platform linux/amd64 -v "$PWD/build/kaltoe-timer-linux":/app \
  -v "$PWD/build/render-test":/out -w /app fedora:latest \
  bash -c 'dnf install -y python3-gobject python3-cairo gtk3 libayatana-appindicator-gtk3 webkit2gtk4.1 libnotify >/dev/null 2>&1; \
    python3 kaltoe-tray.py --render-test /out/normal.png "2:34" normal && \
    python3 kaltoe-tray.py --render-test /out/warning.png "0:28" warning && \
    python3 kaltoe-tray.py --render-test /out/critical.png "OT -0:59" critical'
```

Expected: three `wrote /out/….png` lines. View the three PNGs (Read tool) and confirm: readable text, gray/orange-pill/red-pill styling, nothing clipped.

- [ ] **Step 5: Final gates + commit**

Run: `swift test 2>&1 | grep -E "Executed" | tail -1` (121 pass) and `python3 -m py_compile linux/kaltoe-tray.py`.

```bash
git add -A  # picks up any Task-4 doc corrections; build/ is gitignored
git commit -m "chore: Fedora container verification for Linux tray v2" --allow-empty
```

(`--allow-empty` because this task may legitimately change nothing if all names were right; the commit records that verification ran — put the verification results in the commit body.)

Hand-over note for the user: the Fedora coworker's live Plasma session is the remaining gate — readable countdown icon at normal/warning/critical, login flow, menu rows; the Ubuntu coworker should see the new menu rows tick.
