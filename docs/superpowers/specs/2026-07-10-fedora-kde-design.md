# Fedora KDE Plasma Support — Design

2026-07-10

## Goal

A coworker runs Fedora with KDE Plasma. Make the existing Linux tarball work
there: verify the Ubuntu-built binary runs on Fedora, document dnf
dependencies, and — the real feature — render the countdown text into the
tray icon on KDE, because Plasma's StatusNotifierItem tray has no label
field (GNOME shows `set_label` text; Plasma shows only the icon).

Same single tarball ships to both the Ubuntu and Fedora coworkers.

## 1. Fedora compatibility verification (container, no code)

In a `fedora:latest` `--platform linux/amd64` container:

- Run the tarball's `kaltoe-core` with an empty `KALTOE_CONFIG_DIR`; expect
  the exact smoke line
  `{"hasSession":false,"icon":"timer","text":"—","urgency":"normal"}`.
  This proves glibc compatibility (static Swift stdlib, dynamic glibc).
- `dnf install` the candidate tray dependencies and run a headless import
  check of the full gi stack (Gtk 3.0, WebKit2 4.1, AyatanaAppIndicator3
  0.1 with AppIndicator3 fallback, PangoCairo, cairo). This pins the exact
  Fedora package names; expected set:
  `python3-gobject python3-cairo gtk3 libayatana-appindicator-gtk3
webkit2gtk4.1 libnotify` (verification step confirms/corrects names).
- If the binary does not run (glibc too old), stop and fall back to a
  static-musl build variant — out of scope for this spec, noted only as
  the contingency.

## 2. Text-in-icon tray mode (`linux/kaltoe-tray.py`)

**Mode selection:** `KALTOE_TRAY_MODE=label|texticon` env override; default
`texticon` when `"KDE"` appears in `XDG_CURRENT_DESKTOP`, else `label`.
GNOME behavior is completely unchanged.

**Rendering:** a `render_text_icon(text, urgency) -> surface` function using
cairo + PangoCairo (no new pip deps; both are part of the PyGObject stack):

- Height 22 px, width to fit the text plus padding (Plasma accepts
  non-square SNI pixmaps; if a real session squares it, that's a smoke-test
  finding — fallback idea recorded below).
- `normal`: text in `#dfdfdf`, transparent background (matches the static
  icons' color).
- `warning` / `critical`: white text on an `#ff9500` / `#ff3b30` rounded
  capsule — the Mac pill, ported.
- Font: default system font via Pango (`Sans Bold 11`), baseline-centered.

**Icon delivery:** AppIndicator icons are looked up by _name_ in the theme
path and cached by name. In texticon mode: create a private temp dir at
startup, `set_icon_theme_path(tempdir)`, write the rendered PNG alternating
between two names (`kaltoe-live-a` / `kaltoe-live-b`) and `set_icon_full`
the fresh one — the name flip defeats the cache. `set_label` is skipped in
this mode (harmless if some tray renders both). Static glyph icons remain
in use for label mode only.

**apply_status change:** compute `text`/`urgency` as today; branch on mode —
label mode = current behavior verbatim; texticon mode = render + swap icon.
Menu, login, notifications, core lifecycle: untouched.

**Render test seam:** `kaltoe-tray.py --render-test <out.png> <text>
<urgency>` renders one icon and exits before any GTK/AppIndicator/DBus
setup. This runs headless in the Fedora container (cairo needs no display),
the PNG is copied out and eyeballed, and it doubles as the regression check
on Ubuntu.

**Known risk (accepted):** whether Plasma displays the wide pixmap without
squashing can only be confirmed on the coworker's machine. If it squashes,
follow-up: render compact stacked two-line text into a square icon.

## 3. Docs

- `linux/README-linux.md`: add a Fedora/KDE subsection under Requirements —
  the `dnf install` line (exact names from §1) — and a note that on KDE the
  countdown is drawn into the icon itself (automatic; `KALTOE_TRAY_MODE`
  overrides). Ubuntu apt list gains `python3-gi-cairo` (needed by the
  renderer; effectively always present with the GTK stack, listed for
  completeness).
- `build/설치가이드-INSTALL-GUIDE.md` (untracked): Ubuntu section retitled
  to cover Linux generally with the two install command variants.

## 4. Testing

- `--render-test` PNGs generated in the Fedora container for
  (`2:34`/normal, `2:34`/warning, `OT -0:59`/critical) and visually checked.
- Headless gi import check passes in the Fedora container.
- `kaltoe-core` smoke line exact-matches in the Fedora container.
- `python3 -m py_compile linux/kaltoe-tray.py`; mode-selection logic unit
  check via `--render-test` on the Mac is impossible (no cairo) — container
  covers it.
- `swift test` (118) untouched — no Swift changes in this spec.
- Rebuild the tarball; final gate remains the coworker's live Plasma
  smoke test (tray shows readable countdown, pill colors at thresholds,
  login works).
