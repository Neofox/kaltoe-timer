# Square Text-Icon for KDE — Design

2026-07-10

## Goal

The Fedora KDE live test confirmed the recorded contingency in
`2026-07-10-fedora-kde-design.md` (§2, known risk): Plasma scales the wide
text pixmap down to its square tray slot, so the countdown reads but is
"pretty small." Rewrite the texticon renderer to produce a square icon with
auto-fitted, optionally stacked text so Plasma renders it at full panel
height — 2–3× larger glyphs.

## Design (`linux/kaltoe-tray.py`, `render_text_icon` only)

- **Canvas:** fixed 64×64 (crisp when Plasma downscales to the slot).
  `ICON_HEIGHT` constant is replaced by `ICON_SIZE = 64`.
- **Line splitting:** if the label contains a space, split at the FIRST
  space into two stacked lines (`OT -0:59` → `OT`/`-0:59`, `BREAK 0:45` →
  `BREAK`/`0:45`); otherwise one line (`2:34`, `--:--`, `—`). Implemented by
  replacing the first space with `\n` and letting a single PangoLayout with
  `Pango.Alignment.CENTER` handle multi-line measurement.
- **Auto-fit:** measure the layout once at a probe size (e.g. 40), then set
  the final size to `probe * min(avail_w / w, avail_h / h)` — Pango pixel
  metrics scale ~linearly with font size. `avail_*` = canvas minus padding.
- **Padding / pill:** warning/critical draw a rounded-square pill filling
  the canvas (corner radius 12, 1 px inset) in the existing `#ff9500` /
  `#ff3b30`, white text, padding 8; normal = `#dfdfdf` text on transparent,
  padding 3.
- **Unchanged:** mode selection, tempdir + `kaltoe-live-a/b` name-flip
  delivery, `--render-test` CLI interface, label mode, menu, everything
  else.

## Testing

- `python3 -m py_compile linux/kaltoe-tray.py` on the Mac.
- Regenerate `--render-test` PNGs in the Fedora container for: `2:34`
  normal, `0:28` warning, `OT -0:59` critical, `BREAK 0:45` normal, `—`
  normal — eyeball each (square, centered, large, correct colors, nothing
  clipped).
- `swift test` untouched (121) — no Swift changes.
- Rebuild the tarball; final gate is the coworker's tray looking bigger.
