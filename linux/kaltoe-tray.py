#!/usr/bin/env python3
"""칼퇴타이머 Linux tray frontend.

Spawns the kaltoe-core daemon, mirrors its NDJSON status lines in an
AppIndicator tray item, and hosts the flex.team login window (WebKitGTK).
Design: docs/superpowers/specs/2026-07-10-linux-build-design.md.
"""
import json
import os
import subprocess
import urllib.parse
from pathlib import Path

import gi

try:
    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.1")
    gi.require_version("Soup", "3.0")
except ValueError as e:
    raise SystemExit(
        f"Missing GTK/WebKit introspection data ({e}).\n"
        "Install the dependencies:\n"
        "  sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1 "
        "gir1.2-webkit2-4.1 libnotify-bin")
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
            "Install it:  sudo apt install gir1.2-ayatanaappindicator3-0.1")
from gi.repository import GLib, Gtk, WebKit2

APP_DIR = Path(__file__).resolve().parent
CORE_BIN = str(APP_DIR / "kaltoe-core")
ICON_DIR = str(APP_DIR / "icons")
CONFIG_DIR = Path(os.environ.get("KALTOE_CONFIG_DIR") or Path.home() / ".config" / "kaltoe-timer")
SESSION_FILE = CONFIG_DIR / "session.json"
LOGIN_URL = "https://flex.team/sign-in"
SESSION_COOKIE_NAMES = {"AID", "V2_WS_AID"}  # mirrors FlexAPIConfig.sessionCookieNames
ICON_BASE = {"timer": "kaltoe-timer", "fork.knife": "kaltoe-fork", "cup.and.saucer": "kaltoe-cup"}
LABEL_GUIDE = "OT +88:88"  # widest label, reserves tray width


class TrayApp:
    def __init__(self):
        self.proc = None
        self.core_gen = 0
        self.buf = b""
        self.has_session = None
        self.login_window = None
        self.indicator = AppIndicator.Indicator.new(
            "kaltoe-timer", "kaltoe-timer", AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_icon_theme_path(ICON_DIR)
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_label("--:--", LABEL_GUIDE)
        self._build_menu()
        self.start_core()

    # ---- menu ----

    def _build_menu(self):
        menu = Gtk.Menu()
        self.status_item = Gtk.MenuItem(label="Starting…")
        self.status_item.set_sensitive(False)
        menu.append(self.status_item)
        menu.append(Gtk.SeparatorMenuItem())

        self.sign_in_item = Gtk.MenuItem(label="Sign in to Flex…")
        self.sign_in_item.connect("activate", self.open_login)
        menu.append(self.sign_in_item)

        self.sign_out_item = Gtk.MenuItem(label="Sign out")
        self.sign_out_item.connect("activate", self.sign_out)
        menu.append(self.sign_out_item)

        refresh_item = Gtk.MenuItem(label="Refresh now")
        refresh_item.connect("activate", self.request_refresh)
        menu.append(refresh_item)

        self.restart_item = Gtk.MenuItem(label="Restart core")
        self.restart_item.connect("activate", self.start_core)
        menu.append(self.restart_item)

        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self.quit)
        menu.append(quit_item)

        menu.show_all()
        self.restart_item.hide()
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
        self.indicator.set_label(text, LABEL_GUIDE)
        self.indicator.set_icon_full(icon, text)

        has_session = status.get("hasSession", False)
        parts = []
        if not has_session:
            parts.append("Signed out")
        if status.get("syncError"):
            parts.append(status["syncError"])
        if status.get("lastSync"):
            parts.append("Synced " + status["lastSync"].replace("T", " ")[:16])
        self.status_item.set_label(" · ".join(parts) or "OK")
        self.sign_in_item.set_visible(not has_session)
        self.sign_out_item.set_visible(has_session)

        if self.has_session and not has_session:
            subprocess.run(["notify-send", "칼퇴타이머",
                            "Flex session expired — sign in again to keep tracking."],
                           check=False)
        self.has_session = has_session

    # ---- login (mirrors macOS LoginWindowController) ----

    def open_login(self, *_):
        if self.login_window:
            self.login_window.present()
            return
        win = Gtk.Window(title="Sign in to Flex")
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
    if not os.path.exists(CORE_BIN):
        raise SystemExit(f"kaltoe-core binary not found next to this script: {CORE_BIN}\n"
                         "Run from the installed directory (see README-linux.md).")
    TrayApp()
    Gtk.main()


if __name__ == "__main__":
    main()
