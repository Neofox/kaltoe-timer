# Menu bar label — what only hardware can confirm

Spec: `specs/2026-07-30-menu-bar-overhaul-design.md`. Almost every item here is a
claim the unit tests cannot reach, because `ImageRenderer` output is not assertable.
Three are partly covered — the 자유! minute is asserted in `LabelVocabularyTests`, and
the fill's advance through lunch and its monotonicity follow from `dayProgress` being
`elapsed / span` over a phase-independent denominator, covered in
`WorkCalculatorTests` — so what hardware adds for those is *seeing the rendered fill
do it*, not the arithmetic.

## Both geometries

- [ ] Ring and Track are each legible at a glance on a dark menu bar.
- [ ] Both are legible on a **light** menu bar. Track is the risk: its text stays
      the bar's own colour instead of flipping to white, while the fill behind it is
      drawn at full opacity — and the near-칼퇴 orange fill under dark text was the
      one mockup cell that looked wrong.
- [ ] Neither clashes with macOS 26's tinted / translucent menu bar over a busy
      wallpaper.
- [ ] The countdown text contrasts with the bar **as it is actually drawn**, not as
      the system appearance says. Try Light appearance over a dark wallpaper, and Dark
      appearance over a light one: macOS will draw light menu bar text over a dark
      wallpaper while the appearance is still Light, and `barForeground` is
      `colorScheme == .dark ? .white : .black` baked into a non-template raster, in
      every state. A template image would have inverted by itself; this raster cannot.
      This is the control that replaced the retired high-contrast preference — before
      the overhaul the exposure was bounded, because the template `.plain` path was the
      default and the alerting `.pill` baked white on a saturated fill. The new
      working-day and idle states bake black-or-white text over a faint or transparent
      background, which is the combination that fails.
- [ ] Switching geometry in the popover re-renders the label immediately.
- [ ] The segmented picker looks right inset 12pt in the 280pt popover, and its two
      segments do not crowd. Never seen at real width.
- [ ] VoiceOver announces the picker as "Menu bar label style" and the segments as
      "Ring"/"Track", with no doubled announcement. No screen reader was available
      during implementation, so this is unverified in either direction.
- [ ] Neither geometry is clipped or vertically off-centre in the 22pt bar.
- [ ] The ring still matches the text after raising the system menu bar text size.
      `ringSize` and the inner glyph are hardcoded at 18pt and 9pt, but the label font
      is `NSFont.menuBarFont(ofSize: 0)`, which honours that setting — so the text can
      grow while the ring cannot follow. 18 already leaves only 2pt either side of the
      22pt bar, so the ring has no room to grow with it.
- [x] Idle CPU with the popover closed. **Measured 2026-07-31: 3%**, and accepted.
      Rasterisation is unconditional at 1 Hz where the old default `.plain` path
      rasterised nothing, so this is a real new cost rather than unchanged. Worth
      knowing there is headroom if it ever grates: the rendered content changes only
      once a minute for the text, and the ring's fill advances sub-pixel per second, so
      almost every one of those renders is redundant. Memoising on the visible inputs
      would cut most of it.

- [ ] `beach.umbrella` is legible at 9pt inside the ring. It is a detailed glyph and
      may mush at that size; `sun.max` is the cleaner fallback, at the cost of meaning
      "sunny" rather than "weekend". Only observable on a Saturday or Sunday.
- [ ] The KDE text-icon path renders `주말!` rather than tofu boxes. Pango should
      resolve it, but that tray has never rendered Korean before.

## The spectrum

- [ ] The four working-day stops are distinguishable from each other in passing,
      not just side by side.
- [ ] The light-appearance spectrum values hold contrast. Only `#4f9e3c` (green) was
      specified; the other three were derived and are the most likely to need
      adjusting. The alerting colours need no check here — they are the system
      colours, not tuned values.
- [ ] The label's over-target orange is indistinguishable from the week strip's
      orange with the popover open beneath it. Both resolve to the same
      `Color.orange`, so any visible difference means the resolution path is wrong.
- [ ] The limit red reads as an escalation from the orange, not as a second warning
      colour. It has no counterpart in the strip — the weekly cap shows there as
      text — so it is the label's alone.

## Behaviour through a day

- [ ] The fill advances through the lunch break instead of stalling.
- [ ] The fill does not jump backwards when the countdown switches from
      counting-to-lunch to counting-to-leave.
- [ ] 자유! appears for the first minute of overtime and then gives way to `+0:01`.
- [ ] Label width does not visibly jitter as the digits tick.
- [ ] A second display's menu bar shows the label at full contrast while unfocused
      — the guarantee that replaced the retired setting.

## Signed out

- [ ] `zzz` alone, with no text, reads as signed out rather than as a bug.
- [ ] VoiceOver announces "Signed out" on it.
