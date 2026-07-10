# Square Text-Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the KDE tray countdown big: replace the wide 22-px text icon (which Plasma scales down to a square slot) with a 64×64 square icon whose text is auto-fitted and stacked.

**Architecture:** Rewrite only `render_text_icon` in `linux/kaltoe-tray.py`: split the label at its first space into a two-line centered PangoLayout, measure at a probe font size, scale to fit the padded canvas, draw over a rounded-square pill at warning/critical. Everything around it (mode selection, icon-name flip delivery, `--render-test`) is untouched.

**Tech Stack:** Python 3, cairo + Pango/PangoCairo via PyGObject; Docker `fedora:latest` for render verification.

**Spec:** `docs/superpowers/specs/2026-07-10-square-texticon-design.md`

## Global Constraints

- Square canvas `ICON_SIZE = 64` (replaces `ICON_HEIGHT = 22`); no other module constant changes.
- Split at the FIRST space only: `OT -0:59` → `OT`/`-0:59`; no-space labels stay one line.
- Auto-fit: probe at font size 40, final size = `probe * min(avail_w/w, avail_h/h)`; `avail` = canvas − 2×padding. Padding: 8 (pill) / 3 (normal).
- Pill: rounded square, corner radius 12, 1 px inset, existing colors `#ff9500`/`#ff3b30`, white text; normal = `#dfdfdf` on transparent.
- `render_text_icon(text, urgency, out_path)` signature and the `--render-test` CLI unchanged.
- `python3 -m py_compile` clean; `swift test` untouched at 121; tarball rebuilt at the end with byte-matched tray.

---

### Task 1: Square auto-fit renderer + verification + reship

**Files:**

- Modify: `linux/kaltoe-tray.py:66-104` (the `ICON_HEIGHT`/`PILL_COLORS` constants and `render_text_icon` only)

**Interfaces:**

- Consumes/Produces: `render_text_icon(text, urgency, out_path)` — same signature; `_set_text_icon` and `main()` call sites need no changes.

- [ ] **Step 1: Replace the constants and renderer**

Replace lines from `ICON_HEIGHT = 22` through the end of `render_text_icon` with:

```python
ICON_SIZE = 64
PILL_COLORS = {"warning": (1.0, 0.584, 0.0), "critical": (1.0, 0.231, 0.188)}
FONT_PROBE_SIZE = 40


def render_text_icon(text, urgency, out_path):
    """Render the tray label into a square PNG so Plasma shows it at full
    panel height: auto-fitted text (stacked at the first space), plain
    light-gray normally, white on an orange/red rounded square at
    warning/critical (the Mac pill)."""
    stacked = text.replace(" ", "\n", 1)
    pad = 8 if urgency in PILL_COLORS else 3
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
    surface.write_to_png(out_path)
```

There must be no other `ICON_HEIGHT` reference left: `rg -n ICON_HEIGHT linux/kaltoe-tray.py` must return nothing.

- [ ] **Step 2: Syntax check**

Run: `python3 -m py_compile linux/kaltoe-tray.py && rm -rf linux/__pycache__ && echo OK`
Expected: `OK`

- [ ] **Step 3: Render verification in the Fedora container**

```bash
rm -rf build/render-test && mkdir -p build/render-test
docker run --rm --platform linux/amd64 -v "$PWD/linux":/app -v "$PWD/build/render-test":/out -w /app fedora:latest \
  bash -c 'dnf install -y python3-gobject python3-cairo gtk3 libayatana-appindicator-gtk3 webkit2gtk4.1 libnotify gobject-introspection >/dev/null 2>&1; \
    python3 kaltoe-tray.py --render-test /out/normal.png "2:34" normal && \
    python3 kaltoe-tray.py --render-test /out/warning.png "0:28" warning && \
    python3 kaltoe-tray.py --render-test /out/critical.png "OT -0:59" critical && \
    python3 kaltoe-tray.py --render-test /out/break.png "BREAK 0:45" normal && \
    python3 kaltoe-tray.py --render-test /out/dash.png "—" normal'
```

Expected: five `wrote /out/….png` lines. View each PNG (Read tool) and confirm: 64×64 square; `2:34` one big line; `OT -0:59` stacked `OT` over `-0:59` on a red rounded square; `BREAK 0:45` stacked; `—` doesn't look broken; nothing clipped; correct colors.

- [ ] **Step 4: Full gates**

Run: `swift test 2>&1 | grep -E "Executed" | tail -1` → `Executed 121 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add linux/kaltoe-tray.py
git commit -m "fix: square auto-fit text icon so Plasma renders it full-size"
```

- [ ] **Step 6: Rebuild and verify the tarball**

Run: `./scripts/build-linux.sh && tar xzf build/kaltoe-timer-linux-x86_64.tar.gz -O kaltoe-timer-linux/kaltoe-tray.py | diff - linux/kaltoe-tray.py && echo TRAY_MATCHES`
Expected: `Built …` then `TRAY_MATCHES`.
