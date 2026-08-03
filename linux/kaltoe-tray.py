#!/usr/bin/python3
"""칼퇴타이머 Linux tray frontend.

Spawns the kaltoe-core daemon, mirrors its NDJSON status lines in an
AppIndicator tray item, and hosts the flex.team login window (WebKitGTK).
Design: docs/superpowers/specs/2026-07-10-linux-build-design.md.
"""
import json
import math
import os
import subprocess
import sys
import tempfile
import urllib.parse
from datetime import datetime
from pathlib import Path

# CPython already prepends the script's own directory, so the plain launch path
# imports the sibling module without help. This defends the launches where it
# does not: `python3 -P kaltoe-tray.py` or PYTHONSAFEPATH=1 in the environment,
# either of which drops that entry and turns the import below into a hard
# ModuleNotFoundError at startup. kaltoe_rows is GTK-free, hence safe to import
# above the `gi` block.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from kaltoe_border import rgb as border_rgb, segments as border_segments
from kaltoe_rows import day_label, hm

# WebKitGTK's DMABUF/GPU renderer crash-loops on some Wayland+driver combos
# (confirmed on Fedora KDE: repeated internallyFailedLoadTimerFired plus a
# Wayland protocol error that kills the whole app). The login window is the
# only web content we render, so software rendering costs nothing.
# setdefault keeps it overridable (WEBKIT_DISABLE_DMABUF_RENDERER=0).
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")

try:
    import cairo
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.1")
    gi.require_version("Soup", "3.0")
    gi.require_version("Pango", "1.0")
    gi.require_version("PangoCairo", "1.0")
except (ImportError, ValueError) as e:
    # gi and cairo are distro packages: they land in the system interpreter's
    # site-packages and nowhere else. A pyenv shim or an active venv first on
    # PATH therefore fails here no matter how many packages get installed, so
    # name the interpreter before listing packages that may already be there.
    wrong_python = "" if sys.executable.startswith("/usr/bin/") else (
        f"\nRunning under {sys.executable} —\n"
        "not the system Python, so distro-installed modules are invisible to "
        "it.\nRerun with:  "
        f"/usr/bin/python3 {Path(__file__).resolve()}\n")
    raise SystemExit(
        f"Missing GTK/WebKit introspection data ({e}).\n{wrong_python}"
        "Install the dependencies:\n"
        "  Ubuntu: sudo apt install python3-gi python3-gi-cairo "
        "gir1.2-ayatanaappindicator3-0.1 gir1.2-webkit2-4.1 libnotify-bin "
        "librsvg2-common\n"
        "  Fedora: sudo dnf install python3-gobject python3-cairo gtk3 "
        "gobject-introspection libayatana-appindicator-gtk3 webkit2gtk4.1 "
        "libnotify librsvg2")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except ValueError:  # older distros ship the pre-Ayatana name
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as AppIndicator
    except ValueError:
        raise SystemExit(
            "No AppIndicator introspection data found.\n"
            "Install it:  sudo apt install gir1.2-ayatanaappindicator3-0.1\n"
            "         or  sudo dnf install libayatana-appindicator-gtk3")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango, PangoCairo, WebKit2

APP_DIR = Path(__file__).resolve().parent
CORE_BIN = str(APP_DIR / "kaltoe-core")
ICON_DIR = str(APP_DIR / "icons")
CONFIG_DIR = Path(os.environ.get("KALTOE_CONFIG_DIR") or Path.home() / ".config" / "kaltoe-timer")
SESSION_FILE = CONFIG_DIR / "session.json"
LOGIN_URL = "https://flex.team/sign-in"
SESSION_COOKIE_NAMES = {"AID", "V2_WS_AID"}  # mirrors FlexAPIConfig.sessionCookieNames
ICON_BASE = {"timer": "kaltoe-timer", "fork.knife": "kaltoe-fork", "cup.and.saucer": "kaltoe-cup"}
LABEL_GUIDE = "OT +88:88"  # widest label, reserves tray width
# Plasma's StatusNotifierItem tray has no label field, so on KDE the
# countdown text is rendered into the icon itself.
TRAY_MODE = os.environ.get("KALTOE_TRAY_MODE") or (
    "texticon" if "KDE" in os.environ.get("XDG_CURRENT_DESKTOP", "") else "label")

ICON_SIZE = 64
PILL_COLORS = {"warning": (1.0, 0.584, 0.0), "critical": (1.0, 0.231, 0.188)}
FONT_PROBE_SIZE = 40
# Border metrics, in the 64pt icon's own units. The width is what carries the
# colour — the same lesson the Mac ring learned at 2pt, scaled up: this canvas is
# 64 where that ring is 18, so 5 here is the lighter stroke of the two.
BORDER_INSET = 2
BORDER_WIDTH = 5
BORDER_RADIUS = 10
# No breathing gap between the border and the digits, deliberately: the text
# auto-fits whatever this leaves, and the icon is resampled to a ~22px panel
# where every point matters.
#
# Settled by rendering 7, 8 and 10 through `--render-test` and comparing at
# panel size. The single-line countdown — what the panel shows for almost the
# whole day — is clearly sharpest at 7 and visibly compressed by 10. The
# two-line break label is the tightest thing the tray draws, and it is marginal
# at all three, so it cannot earn the padding: no value rescues it, and paying
# for it would blunt the case that is on screen all day.
#
# (An earlier revision justified this the other way round, claiming the gap
# turned the break label to mush. That was measured against a stand-in renderer
# using Cairo's toy text API. Pango disagrees — if anything the break label is
# a touch crisper at 10 — so the conclusion held and the reason did not.)
BORDER_PAD = BORDER_INSET + BORDER_WIDTH
# Ring metrics for label mode, same 64pt canvas. Proportioned off the Mac's ring
# — an 18pt circle with a 2pt stroke around a 9pt glyph — which is the geometry
# this mode already has: a glyph with the countdown beside it, exactly what
# MenuBarLabel draws. The glyph gives up room to the ring, as it does there.
#
# The Mac gives its glyph half the ring's diameter; this gives it two thirds,
# chosen by rendering 7/35, 6/39 and 5/43 through `--render-ring` and judging
# them resampled to 22px. The glyph loses far more to a thick ring here than the
# reasoning-by-proportion suggested — at 35 the cup and the stopwatch are barely
# separable on a panel — while the ring itself still reads clearly at 5, which
# is the same 5-in-64 stroke the KDE border already proves legible. On GNOME the
# countdown is text beside the icon, so the glyph is the only thing naming the
# app in the panel; it gets the room.
RING_INSET = 3.5
RING_WIDTH = 5.0
RING_GLYPH = 43.0


def render_text_icon(text, urgency, out_path, fill=None, color=None):
    """Render the tray label into a square PNG so Plasma shows it at full
    panel height: auto-fitted text (stacked at the first space), plain
    light-gray normally, white on an orange/red rounded square at
    warning/critical (this tray's own alert badge — the only place the urgency
    colours reach the label *text*; on the icon path they arrive instead as the
    -warning/-critical icon variants, stroked in the same two colours).

    `fill` (0…1) and `color` ('#rrggbb') come straight off the wire and draw a
    progress border round the icon — the tray's answer to the Mac's ring, and
    the same number behind it, so the border closes as the countdown reaches
    zero. It is suppressed at warning and critical: the pill already fills the
    whole square in those states, and a border round a solid block of colour
    reads as a rendering fault rather than as progress."""
    stacked = text.replace(" ", "\n", 1)
    bordered = urgency not in PILL_COLORS and border_rgb(color) is not None
    # The border needs its own room — see BORDER_PAD, which is exactly the inset
    # and the stroke with nothing spare. This is the feature's real cost: the
    # text auto-fits whatever is left, so every point here comes off the
    # countdown's size, and at panel scale the countdown is the whole point.
    pad = 8 if urgency in PILL_COLORS else (BORDER_PAD if bordered else 3)
    avail = ICON_SIZE - 2 * pad

    def make_layout(cr, size):
        layout = PangoCairo.create_layout(cr)
        layout.set_font_description(Pango.FontDescription(f"Sans Bold {size}"))
        layout.set_alignment(Pango.Alignment.CENTER)
        layout.set_text(stacked, -1)
        return layout

    # Measure at a probe size, then scale to fit the padded canvas
    # (Pango pixel metrics scale ~linearly with font size).
    probe_surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1)
    probe = make_layout(cairo.Context(probe_surface), FONT_PROBE_SIZE)
    probe_w, probe_h = probe.get_pixel_size()
    size = max(1, int(FONT_PROBE_SIZE * min(avail / probe_w, avail / probe_h)))

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, ICON_SIZE, ICON_SIZE)
    cr = cairo.Context(surface)

    if urgency in PILL_COLORS:
        r, g, b = PILL_COLORS[urgency]
        radius = 12
        inset = 1
        right, bottom = ICON_SIZE - inset, ICON_SIZE - inset
        cr.set_source_rgb(r, g, b)
        cr.arc(inset + radius, inset + radius, radius, 3.14159, 1.5 * 3.14159)
        cr.arc(right - radius, inset + radius, radius, 1.5 * 3.14159, 2 * 3.14159)
        cr.arc(right - radius, bottom - radius, radius, 0, 0.5 * 3.14159)
        cr.arc(inset + radius, bottom - radius, radius, 0.5 * 3.14159, 3.14159)
        cr.close_path()
        cr.fill()
        cr.set_source_rgb(1, 1, 1)
    else:
        cr.set_source_rgb(0.875, 0.875, 0.875)  # dfdfdf, matches static icons

    layout = make_layout(cr, size)
    text_w, text_h = layout.get_pixel_size()
    cr.move_to((ICON_SIZE - text_w) / 2, (ICON_SIZE - text_h) / 2)
    PangoCairo.show_layout(cr, layout)

    if bordered:
        _stroke_border(cr, 1.0, (1, 1, 1, 0.18))      # the unfilled remainder
        _stroke_border(cr, fill, border_rgb(color) + (1.0,))

    surface.write_to_png(out_path)


def render_glyph_icon(svg_path, out_path, fill, color):
    """Draw the tray glyph inside a progress ring, for the label-mode panels.

    GNOME (and anything that is not KDE) puts the countdown in the indicator's
    own label and shows a small icon beside it, so the KDE trick of drawing the
    time *into* the icon has nothing to add there — but the icon itself was a
    static SVG carrying no progress at all, while KDE gained a border. This is
    the same information in the shape that fits: a ring round the glyph, which
    is what the Mac has always drawn for the identical layout.

    The glyph is loaded from the very SVG the static path ships rather than
    redrawn in Cairo, so there is one copy of the artwork and the ringed icon
    cannot drift from the plain one. GdkPixbuf reads it through the librsvg
    loader that any desktop rendering an icon theme already has; the caller
    treats a failure here as "fall back to the static icon" rather than as an
    error, so a machine without that loader keeps today's tray.
    """
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, ICON_SIZE, ICON_SIZE)
    cr = cairo.Context(surface)
    centre = ICON_SIZE / 2
    radius = centre - RING_INSET - RING_WIDTH / 2

    cr.set_line_width(RING_WIDTH)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.new_path()
    cr.set_source_rgba(1, 1, 1, 0.20)
    cr.arc(centre, centre, radius, 0, 2 * math.pi)
    cr.stroke()
    if fill and fill > 0:
        cr.new_path()
        cr.set_source_rgb(*color)
        # From twelve o'clock, like the Mac ring and the KDE border.
        cr.arc(centre, centre, radius, -math.pi / 2, -math.pi / 2 + 2 * math.pi * min(1.0, fill))
        cr.stroke()

    pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(svg_path, int(RING_GLYPH), int(RING_GLYPH))
    offset = (ICON_SIZE - RING_GLYPH) / 2
    Gdk.cairo_set_source_pixbuf(cr, pixbuf, offset, offset)
    cr.paint()
    surface.write_to_png(out_path)


def _stroke_border(cr, fill, rgba):
    """Stroke `fill` of the perimeter in one pass.

    Segments are emitted in walk order and every one begins where the last
    ended, so a single path keeps the corners mitred — stroking them
    individually would leave a seam at each joint. Cairo's `arc` draws a
    connecting line from the current point when there is one, which is exactly
    the join wanted here since the endpoints coincide."""
    path = border_segments(fill, ICON_SIZE, BORDER_INSET, BORDER_RADIUS)
    if not path:
        return
    cr.save()
    cr.new_path()
    cr.set_line_width(BORDER_WIDTH)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_source_rgba(*rgba)
    for index, segment in enumerate(path):
        if segment[0] == "line":
            _, x1, y1, x2, y2 = segment
            if index == 0:
                cr.move_to(x1, y1)
            cr.line_to(x2, y2)
        else:
            # No move_to even when an arc leads: with radius at half the side the
            # straights vanish and the walk opens on a corner, and `arc` with no
            # current point simply starts there.
            _, cx, cy, radius, a0, a1 = segment
            cr.arc(cx, cy, radius, a0, a1)
    cr.stroke()
    cr.restore()


class TrayApp:
    def __init__(self):
        self.proc = None
        self.core_gen = 0
        self.buf = b""
        self.has_session = None
        self.leave_at_dt = None
        self.login_window = None
        self.indicator = AppIndicator.Indicator.new(
            "kaltoe-timer", "kaltoe-timer", AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_icon_theme_path(ICON_DIR)
        self.texticon = TRAY_MODE == "texticon"
        self.icon_seq = 0
        # Both modes now write generated PNGs, so the temp dir is no longer the
        # text-icon path's alone. `rings` starts optimistic and latches off the
        # first time GdkPixbuf cannot read the SVG — a desktop without the
        # librsvg loader then keeps the static icons instead of a blank tray.
        self.rings = not self.texticon
        self.icon_temp = tempfile.mkdtemp(prefix="kaltoe-tray-")
        self._theme_path = None
        self._use_theme_path(self.icon_temp if self.texticon else ICON_DIR)
        if self.texticon:
            self._set_text_icon("--:--", "normal")
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        if not self.texticon:
            self.indicator.set_label("--:--", LABEL_GUIDE)
        self._build_menu()
        self.start_core()
        GLib.timeout_add_seconds(1, self._tick)

    # ---- menu ----

    def _build_menu(self):
        menu = Gtk.Menu()
        self.started_item = Gtk.MenuItem(label="")
        self.started_item.set_sensitive(False)
        menu.append(self.started_item)

        self.leave_item = Gtk.MenuItem(label="")
        self.leave_item.set_sensitive(False)
        menu.append(self.leave_item)

        self.target_item = Gtk.MenuItem(label="")
        self.target_item.set_sensitive(False)
        menu.append(self.target_item)

        self.timeleft_item = Gtk.MenuItem(label="")
        self.timeleft_item.set_sensitive(False)
        menu.append(self.timeleft_item)

        self.day_separators = [Gtk.SeparatorMenuItem(), Gtk.SeparatorMenuItem()]
        menu.append(self.day_separators[0])
        self.day_items = []
        for _ in range(5):
            item = Gtk.MenuItem(label="")
            item.set_sensitive(False)
            menu.append(item)
            self.day_items.append(item)
        menu.append(self.day_separators[1])

        self.ot_item = Gtk.MenuItem(label="")
        self.ot_item.set_sensitive(False)
        menu.append(self.ot_item)

        menu.append(Gtk.SeparatorMenuItem())

        self.status_item = Gtk.MenuItem(label="시작 중…")
        self.status_item.set_sensitive(False)
        menu.append(self.status_item)
        menu.append(Gtk.SeparatorMenuItem())

        self.sign_in_item = Gtk.MenuItem(label="Flex 로그인…")
        self.sign_in_item.connect("activate", self.open_login)
        menu.append(self.sign_in_item)

        self.sign_out_item = Gtk.MenuItem(label="로그아웃")
        self.sign_out_item.connect("activate", self.sign_out)
        menu.append(self.sign_out_item)

        refresh_item = Gtk.MenuItem(label="Flex 재동기화")
        refresh_item.connect("activate", self.request_refresh)
        menu.append(refresh_item)

        self.restart_item = Gtk.MenuItem(label="코어 재시작")
        self.restart_item.connect("activate", self.start_core)
        menu.append(self.restart_item)

        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="종료")
        quit_item.connect("activate", self.quit)
        menu.append(quit_item)

        menu.show_all()
        self.restart_item.hide()
        for item in (self.started_item, self.leave_item, self.target_item,
                     self.timeleft_item, self.ot_item,
                     *self.day_items, *self.day_separators):
            item.hide()
        self.indicator.set_menu(menu)

    # ---- core subprocess ----

    def start_core(self, *_):
        self.stop_core()
        self.core_gen += 1
        gen = self.core_gen
        try:
            self.proc = subprocess.Popen([CORE_BIN], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE)
        except OSError as e:
            self.on_core_dead(f"core failed to start: {e}")
            return
        self.restart_item.hide()
        self.buf = b""
        GLib.io_add_watch(self.proc.stdout.fileno(), GLib.IO_IN | GLib.IO_HUP,
                          lambda fd, cond: self.on_core_output(fd, cond, gen))

    def stop_core(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None

    def on_core_dead(self, message):
        self.leave_at_dt = None
        for item in (self.started_item, self.leave_item, self.target_item,
                     self.timeleft_item, self.ot_item,
                     *self.day_items, *self.day_separators):
            item.hide()
        if self.texticon:
            self._set_text_icon("--:--", "normal")
        else:
            self.indicator.set_label("--:--", LABEL_GUIDE)
            self.indicator.set_icon_full("kaltoe-timer", "core stopped")
        self.status_item.set_label(message)
        self.restart_item.show()

    def on_core_output(self, fd, cond, gen):
        if gen != self.core_gen:
            return False  # watch for a previous core generation — drop it
        chunk = b""
        if cond & GLib.IO_IN:
            chunk = os.read(fd, 65536)
            self.buf += chunk
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                self.apply_status(line)
        if (cond & GLib.IO_HUP) and not chunk:
            self.on_core_dead("core stopped — use Restart core")
            return False
        return True

    def request_refresh(self, *_):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.write(b"refresh\n")
                self.proc.stdin.flush()
            except OSError:
                pass

    # ---- status rendering ----

    @staticmethod
    def _local_sync_label(iso_utc):
        try:
            dt = datetime.fromisoformat(iso_utc.replace("Z", "+00:00"))
        except ValueError:
            return iso_utc
        return dt.astimezone().strftime("%Y-%m-%d %H:%M")

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

    def apply_status(self, raw):
        try:
            status = json.loads(raw)
        except ValueError:
            return
        text = status.get("text", "--:--")
        icon = ICON_BASE.get(status.get("icon"), "kaltoe-timer")
        urgency = status.get("urgency", "normal")
        if urgency in ("warning", "critical"):
            icon = f"{icon}-{urgency}"
        if self.texticon:
            self._set_text_icon(text, urgency,
                                fill=status.get("fill"), color=status.get("fillColor"))
        else:
            self.indicator.set_label(text, LABEL_GUIDE)
            # The ring carries what the border carries on KDE. Suppressed at
            # warning and critical for the same reason: those states already
            # recolour the whole glyph, and a progress ring around an alarm is
            # a second thing to read at the moment there is least time to.
            ringed = (self.rings and urgency not in PILL_COLORS
                      and self._set_glyph_icon(icon, text, status.get("fill"),
                                               status.get("fillColor")))
            if not ringed:
                self._use_theme_path(ICON_DIR)
                self.indicator.set_icon_full(icon, text)

        has_session = status.get("hasSession", False)
        parts = []
        if not has_session:
            parts.append("세션 만료")
        if status.get("syncError"):
            parts.append(status["syncError"])
        if status.get("lastSync"):
            parts.append("동기화 " + self._local_sync_label(status["lastSync"]))
        self.status_item.set_label(" · ".join(parts) or "정상")

        started = self._parse_iso(status.get("started"))
        self.leave_at_dt = self._parse_iso(status.get("leaveAt"))
        week_ot = status.get("weekOvertime")

        self.started_item.set_visible(started is not None)
        if started:
            self.started_item.set_label(f"출근 {self._local_hhmm(started)}")
        self.leave_item.set_visible(self.leave_at_dt is not None)
        if self.leave_at_dt:
            self.leave_item.set_label(f"퇴근 예정 {self._local_hhmm(self.leave_at_dt)}")
        self.timeleft_item.set_visible(self.leave_at_dt is not None)
        self.ot_item.set_visible(week_ot is not None)
        if week_ot is not None:
            label = f"주간 초과근무 {self._signed_hm(week_ot)}"
            cap = status.get("weekOvertimeCap")
            if cap is not None:
                label += f" / {hm(cap)}"
            self.ot_item.set_label(label)

        note = status.get("targetNote")
        self.target_item.set_visible(bool(note))
        if note:
            self.target_item.set_label("  " + note)

        days = status.get("days") or []
        # Mirror the popover, which hides the strip entirely until some day has
        # hours (`days.contains(where: { $0.worked != nil })` in MenuBarView). The
        # wire ships all five rows unconditionally, so without this gate a fresh
        # Monday morning shows five bare labels on Linux and nothing on macOS.
        if not any(day.get("worked") is not None for day in days):
            days = []
        for item, day in zip(self.day_items, days):
            item.set_label(day_label(day))
            item.set_visible(True)
        for item in self.day_items[len(days):]:
            item.set_visible(False)
        for separator in self.day_separators:
            separator.set_visible(bool(days))
        self._tick()

        self.sign_in_item.set_visible(not has_session)
        self.sign_out_item.set_visible(has_session)

        if self.has_session and not has_session:
            subprocess.run(["notify-send", "칼퇴타이머",
                            "Flex 세션이 만료되었습니다 — 계속 기록하려면 다시 로그인해 주세요."],
                           check=False)
        self.has_session = has_session

    def _use_theme_path(self, path):
        """Point the indicator at a directory, but only when it changes.

        Label mode alternates between two: generated rings live in the temp
        dir, the warning and critical glyphs are shipped SVGs in ICON_DIR. Set
        the wrong one and `set_icon_full` names a file that is not there — the
        first cut of the ring did exactly that, leaving the alert states with
        no icon at the moment they matter most. Guarded on change because this
        runs on the one-second tick."""
        if self._theme_path != path:
            self.indicator.set_icon_theme_path(path)
            self._theme_path = path

    def _publish_icon(self, text, render):
        # Icons travel by NAME (appindicator → SNI → Plasma's icon loader),
        # and Plasma caches pixmaps per name for the whole session — reusing
        # names froze the tray at the first renders (seen live: icon 15 min
        # behind the menu). A never-reused name defeats every cache layer;
        # prune old files so the temp dir stays at two PNGs.
        #
        # Shared by both modes since label mode started generating icons too.
        # Whether GNOME's appindicator extension caches as aggressively as
        # Plasma is unknown, and the flip costs nothing on a desktop that does
        # not need it — where guessing wrong the other way is a tray frozen on
        # the first ring it ever drew.
        self.icon_seq += 1
        name = f"kaltoe-live-{self.icon_seq}"
        render(os.path.join(self.icon_temp, name + ".png"))
        self.indicator.set_icon_full(name, text)
        stale = os.path.join(self.icon_temp, f"kaltoe-live-{self.icon_seq - 2}.png")
        if os.path.exists(stale):
            os.remove(stale)

    def _set_text_icon(self, text, urgency, fill=None, color=None):
        self._publish_icon(text, lambda path: render_text_icon(
            text, urgency, path, fill=fill, color=color))

    def _set_glyph_icon(self, icon, text, fill, color):
        """Ringed glyph for label mode, falling back to the static SVG.

        Returns False when the ring could not be drawn, which latches `rings`
        off: the failure is a missing SVG loader, so it will not fix itself on
        the next tick and retrying every second would just churn."""
        rgb = border_rgb(color)
        if rgb is None or fill is None:
            return False
        try:
            self._use_theme_path(self.icon_temp)
            self._publish_icon(text, lambda path: render_glyph_icon(
                os.path.join(ICON_DIR, icon + ".svg"), path, fill, rgb))
            return True
        except Exception:
            self.rings = False
            return False

    def _tick(self):
        if self.leave_at_dt:
            left = max(0, int((self.leave_at_dt - datetime.now().astimezone()).total_seconds()))
            self.timeleft_item.set_label(
                f"남은 시간 {left // 3600}:{(left % 3600) // 60:02d}:{left % 60:02d}")
        return True

    # ---- login (mirrors macOS LoginWindowController) ----

    def open_login(self, *_):
        if self.login_window:
            self.login_window.present()
            return
        win = Gtk.Window(title="Flex 로그인")
        win.set_default_size(480, 680)
        web = WebKit2.WebView()
        web.connect("load-changed", self.on_load_changed)
        win.add(web)
        win.connect("destroy", self.on_login_closed)
        win.show_all()
        web.load_uri(LOGIN_URL)
        self.login_window = win

    def on_login_closed(self, *_):
        self.login_window = None

    def on_load_changed(self, web, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        manager = web.get_website_data_manager().get_cookie_manager()
        manager.get_cookies("https://flex.team", None, self.on_cookies_ready)

    def on_cookies_ready(self, manager, result):
        try:
            cookies = manager.get_cookies_finish(result)
        except GLib.Error:
            return
        flex = [c for c in cookies if "flex.team" in c.get_domain()]
        names = {c.get_name() for c in flex}
        if not SESSION_COOKIE_NAMES <= names:
            return  # not logged in yet — keep waiting for later page loads
        user_id_hash = ""
        for c in flex:
            if c.get_name() == "V2_CUSTOMER_INFO":
                try:
                    info = json.loads(urllib.parse.unquote(c.get_value()))
                    user_id_hash = info.get("userIdHash") or ""
                except ValueError:
                    pass
        if not user_id_hash:
            return  # the id cookie hasn't landed yet
        self.write_session(user_id_hash, flex)
        if self.login_window:
            self.login_window.destroy()
        self.start_core()  # restart so the core picks up the new session

    @staticmethod
    def expires_epoch(cookie):
        expires = cookie.get_expires()  # GLib.DateTime or None (session cookie)
        return expires.to_unix() if expires else None

    def write_session(self, user_id_hash, cookies):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "userIdHash": user_id_hash,
            "cookies": [
                {"name": c.get_name(), "value": c.get_value(), "domain": c.get_domain(),
                 "path": c.get_path(), "expires": self.expires_epoch(c)}
                for c in cookies
            ],
        }
        fd = os.open(SESSION_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)

    # ---- lifecycle ----

    def sign_out(self, *_):
        SESSION_FILE.unlink(missing_ok=True)
        self.start_core()

    def quit(self, *_):
        self.stop_core()
        Gtk.main_quit()


def main():
    if sys.argv[1:2] == ["--render-test"]:
        if len(sys.argv) < 5:
            raise SystemExit("usage: kaltoe-tray.py --render-test <out.png> <text> "
                             "<urgency> [fill] [#rrggbb]")
        # fill/colour are optional so every existing invocation still means what
        # it did. Supplying them is the only way to see the progress border come
        # out of the real renderer — kaltoe_border's tests prove the geometry,
        # but Pango, the padding and the border share one canvas, and only this
        # path draws all three together.
        fill = float(sys.argv[5]) if len(sys.argv) > 5 else None
        color = sys.argv[6] if len(sys.argv) > 6 else None
        render_text_icon(sys.argv[3], sys.argv[4], sys.argv[2], fill=fill, color=color)
        print(f"wrote {sys.argv[2]}")
        return
    if sys.argv[1:2] == ["--render-ring"]:
        # Label mode's counterpart. Same reason the text seam exists: the ring
        # is a PNG this code draws, and a GNOME panel is not available to look
        # at, so the only honest check is to render the shipped function.
        if len(sys.argv) < 6:
            raise SystemExit("usage: kaltoe-tray.py --render-ring <out.png> <icon-name> "
                             "<fill> <#rrggbb>")
        colour = border_rgb(sys.argv[5])
        if colour is None:
            raise SystemExit(f"unusable colour: {sys.argv[5]}")
        render_glyph_icon(os.path.join(ICON_DIR, sys.argv[3] + ".svg"), sys.argv[2],
                          float(sys.argv[4]), colour)
        print(f"wrote {sys.argv[2]}")
        return
    if not os.path.exists(CORE_BIN):
        raise SystemExit(f"kaltoe-core binary not found next to this script: {CORE_BIN}\n"
                         "Run from the installed directory (see README-linux.md).")
    TrayApp()
    Gtk.main()


if __name__ == "__main__":
    main()
