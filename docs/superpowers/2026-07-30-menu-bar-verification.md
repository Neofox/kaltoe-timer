# Menu bar label — what only hardware can confirm

Spec: `specs/2026-07-30-menu-bar-overhaul-design.md`. Every item here is a claim
the unit tests cannot reach, because `ImageRenderer` output is not assertable.

## Both geometries

- [ ] Ring and Track are each legible at a glance on a dark menu bar.
- [ ] Both are legible on a **light** menu bar. Track is the risk: its text stays
      the bar's own colour instead of flipping to white, while the fill behind it is
      drawn at full opacity — and the near-칼퇴 orange fill under dark text was the
      one mockup cell that looked wrong.
- [ ] Neither clashes with macOS 26's tinted / translucent menu bar over a busy
      wallpaper.
- [ ] Switching geometry in the popover re-renders the label immediately.
- [ ] The segmented picker looks right inset 12pt in the 280pt popover, and its two
      segments do not crowd. Never seen at real width.
- [ ] VoiceOver announces the picker as "Menu bar label style" and the segments as
      "Ring"/"Track", with no doubled announcement. No screen reader was available
      during implementation, so this is unverified in either direction.
- [ ] Neither geometry is clipped or vertically off-centre in the 22pt bar.
- [ ] The ring still matches the text after raising the system menu bar text size.
      `ringSize` and the inner glyph are hardcoded at 14pt and 7pt, but the label font
      is `NSFont.menuBarFont(ofSize: 0)`, which honours that setting — so the text can
      grow while the ring cannot follow.
- [ ] Idle CPU with the popover closed is unchanged from before the overhaul.
      Rasterisation is now unconditional at 1 Hz, where the old default `.plain` path
      rasterised nothing at all. This is the design, not a regression — but it is the
      one cost of it, and it has never been measured.

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
