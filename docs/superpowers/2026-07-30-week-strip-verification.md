# Week strip verification — the macOS popover and the Linux tray

The week-strip branch adds three things: a five-row Mon–Fri strip in the macOS popover,
a caption naming why today's target is shorter than eight hours, and the same per-day
figures as text rows in the Linux tray menu. All three are code-complete and tested.
**None of them has been looked at.** The app was never launched and the tray was never
run on a desktop, so nothing about the rendered appearance — layout, alignment, colour,
whether a row overflows, whether a panel collapses the column spacing — has been
confirmed by anyone.

This document is the whole of what is left. It is written to be executed by someone who
has not read the plan, on two machines, without opening another file.

Feature spec: `docs/superpowers/specs/2026-07-30-popover-week-graph-design.md`.
Plan: `docs/superpowers/plans/2026-07-30-popover-week-graph.md`.

## What is already verified — do not redo it

| Gate                                                     | Result                                               |
| -------------------------------------------------------- | ---------------------------------------------------- |
| Cold build, `rm -rf .build && swift build --build-tests` | No warnings, no errors                               |
| macOS `swift test`                                       | 173 tests, 0 failures                                |
| Linux suite, in `swift:6.3-noble` under `TZ=Asia/Seoul`  | 146 tests, 0 failures                                |
| Tarball staging (`scripts/build-linux.sh` drift guard)   | `kaltoe_rows.py` staged; guard proven to fire        |
| `install.sh` from an extracted tarball, in a container   | exit 0, all 9 icons, autostart entry, module imports |

The Linux suite must run with `TZ=Asia/Seoul` — about thirty date-sensitive tests shift
under the container's default UTC. `scripts/build-linux.sh` now passes it itself, so a
plain run of that script is the supported way to get the number above.

What automation cannot see is everything below: **appearance, layout, and behaviour on a
real menu bar and a real panel.** Two of the checks (A12, A12b) are the only evidence
that exists for the overflow clamp in `WeekBarRow.swift`, because the repo has no
view-test harness.

## Read this before you start

Four constraints decide what you can check and when. Three of them will waste your day
if you meet them halfway through instead of now.

**1. Two macOS checks are mutually exclusive within a single day.** A3 and A5 need you to
be *currently clocked in*. A12 needs you to have **no** Flex record for the day yet,
because `WeekData.weekIncludingManual` ignores a manual start once a real record exists —
the back-dated start A12 relies on is silently discarded after you clock in. You cannot
do both on the same day in one pass. Split it:

- **Before clocking in, late morning (after ~11:10):** A12 and A12b, which verify the
  overflow clamp. Then undo the manual start and clock in normally.
- **While clocked in, any time after:** A1–A7 and A9–A10.
- **Friday 2026-07-31:** A8, the caption.
- **Whenever it happens, or forced:** A11.

Everything else is order-independent.

**2. The caption has a calendar window.** The family-day caption is only observable on the
last Friday of a month. That is **2026-07-31**, and after that **2026-08-28**. There is no
way to fabricate it (see A8 and B6). If that Friday passes without the check, the caption
ships unseen.

**3. The Linux part needs a coworker's machine.** Part B is not runnable on the author's
Mac — there is no GTK, no AppIndicator and no panel here. It needs a real Linux desktop
with the tray installed from the tarball.

**4. Do not move the system clock to fake a state.** Flex sync and session expiry both
read the system clock, and shifting it will poison the day's records. Where a state has
no forcing recipe, this document says so plainly rather than inventing one; skip the step
and check it when the state occurs naturally.

**One standing caution on every `defaults` recipe below.** `defaults delete` reverts a key
to the built-in default, **not** to what you had. These keys are documented user knobs
(`README.md:70-80`) and this app is in use by three coworkers besides its author, so a
blind delete can quietly reset a configured 9h day to 8h and leave the app wrong in a way
that looks like nothing happened. Every recipe therefore opens with a `defaults read` to
capture the current value and closes by writing it back — delete only if the read said the
key did not exist.

---

# Part A — the macOS popover

You need a real session with at least one record this week.

### A0. Bundle and launch

```bash
./scripts/bundle.sh && open ./build/칼퇴타이머.app
```

The bundle is named in Korean. `scripts/bundle.sh:7` sets `APP=build/칼퇴타이머.app` and
line 8 *deletes* any `build/FlexTimer.app` on every run, so the English path fails —
do not "fix" this back. Do not fall back to `swift run FlexTimer` either: that launches a
debug, unbundled binary with no `Info.plist`, hence no `LSUIElement` and a different code
signature, and the popover you would be looking at is not the artefact anyone ships.

Then click the menu bar item to open the popover. Every step below is a look at that one
popover; nothing needs a debugger or a rebuild except where a step says so.

### A1. The section exists at all

Below the `Time left` block and its divider you should see five short rows — `Mon` `Tue`
`Wed` `Thu` `Fri` — stacked above the `Week OT` row.

*Wrong:* no rows at all (the strip is being gated out, or `days` is empty), or six/seven
rows, or the days out of order.

### A2. Nothing is wider than the window

Look down the popover's right edge. The five hour figures on the right should form a clean
vertical column whose right edge lines up exactly with the `Time left` value above them
and the `Week OT` value below them.

*Wrong:* the strip's numbers sit a few points left or right of the numbers above them (the
row has picked up padding of its own), or the window has grown wider than the rest of the
menu, or a bar runs off the right edge.

### A3. The row for the day you are currently clocked in on

While you are on the clock, *that* row's three-letter label should be accent-coloured
where the other four are grey, and its bar should be a *pale* accent fill with a dashed
grey outline continuing ahead of the fill to where the day's target ends.

*Wrong:* no dashed outline (then "in progress" reads as nothing at all — the pale fill
alone is too subtle); the dashed outline appearing on a day you have already clocked out
of; or the fill at full strength so the open day looks identical to Monday's.

**Note, so you don't report a bug that isn't one:** all three cues key on *currently
clocked in*, not on *today*. After you clock out, today's row correctly becomes grey,
full-strength and un-outlined — indistinguishable from any other completed day. That is
right: the cues mean "still running", and nothing is still running. Check this step while
the clock is actually running.

### A4. The notch

Every row has a thin vertical grey tick crossing its bar, standing slightly above and
below it, at the day's target. On an ordinary 8h day it should sit at roughly four-fifths
of the track's width (the track spans 10 hours).

*Wrong:* the tick at the far right end of every track, or missing, or at the very left on
a normal weekday.

### A5. A day past target

Find a day you worked past your target. Its bar should be solid accent up to the notch and
**orange** from the notch onward.

*Wrong:* orange starting before the notch, orange on a day you left early, or the whole
bar orange.

### A6. A short or missing day

A day with no record should be visibly dimmed (about half strength) with a `·` on the
right where the hours would be. A day off should be dimmed the same way and read `off`.

*Wrong:* a dimmed row showing `0:00` instead of `·`/`off`, or a day off reading `·`.

### A7. The right-hand figures agree with the bars

Longest bar = largest number, and the numbers should be plausible hours-and-minutes for
your week.

*Wrong:* a long bar next to a small number, or a number that includes your lunch break.

**One known false alarm, on the open day only.** If you clocked in *after* the lunch window
closed (later than 12:30), the open row's number and its bar come from two different
derivations — the number from `worked`, which has no break deducted because you never took
one, and the orange from `dailyOvertime`, which still charges you the full break. The bar
can therefore sit up to an hour short of what its number implies, and the accent fill can
reach the notch about an hour before the countdown above hits zero. That is documented and
deliberate (`WeekSummary.swift`, `netWorked`) — the bar agrees with the menu bar pill,
which is the agreement that matters. Compare completed days only.

**The same divergence is audible, so don't file it twice.** The spoken label states the
target, so after a post-12:30 start VoiceOver can say
`"worked 9:30 of 8:00, 0:30 over target"` — the two numbers disagree by the untaken break —
and between target and target-plus-break it says `"worked 8:10 of 8:00"` with no
over-target clause at all, because `dailyOvertime` has not started counting yet. Both are
this one documented divergence surfacing in speech, not a second bug in the label.

Worth doing once while you are here: VoiceOver over the day-off row and one completed day,
since those take different branches of `spokenLabel`.

### A8. The caption — **only observable on 2026-07-31, then 2026-08-28**

A small grey line reading e.g. `Target 4:00 · family day` should appear **between**
`Leave at` and `Time left`.

*Wrong:* it appears on an ordinary day; it appears below `Time left` or above `Leave at`;
the `·` renders as a box or vanishes; or it is missing on a day whose `Leave at` is
obviously earlier than usual — that last one is the exact silent-shortening confusion the
caption exists to cure.

**How to reach it.** The caption needs the day's target to be genuinely shorter than
`dailyWork`, which happens on a family day (the last Friday of the month) or with approved
time off. **Neither is forceable with `defaults`:** family day is decided by the calendar
(`WorkCalculator.isFamilyDay`), and time off arrives from Flex. But the date is
cooperative — **Friday 2026-07-31 is the last Friday of July 2026**, and the next one is
**2026-08-28** — so open the popover on that day and it should be there with no setup at
all. `familyDayEarlyLeave` already defaults to 2h, so the feature is on.

To make the reduction unmistakable on the day, enlarge it first; the caption should then
read `Target 4:00 · family day`:

```bash
# Save whatever is there now — `delete` reverts to the built-in 2h and would
# discard a value you configured yourself:
defaults read com.perso.flextimer familyDayEarlyLeaveHours   # note it, or "does not exist"
defaults write com.perso.flextimer familyDayEarlyLeaveHours -float 4.0
# relaunch the app, look, then undo — write the old value back, or delete only
# if the read above said it did not exist:
defaults write com.perso.flextimer familyDayEarlyLeaveHours -float <old value>
defaults delete com.perso.flextimer familyDayEarlyLeaveHours
```

### A9. The day-off wording

On a day off, before clocking in, the popover should read `Day off` where it used to say
`Not clocked in yet`.

*Wrong:* still `Not clocked in yet` on a known day off.

### A10. It stays still

Watch for ten seconds without touching anything. Only today's bar and the numbers should
change, and only smoothly.

*Wrong:* rows jumping, reordering, flickering, or the popover resizing on the tick.

### A11. Signed out

The five rows and `Week OT` should **stay on screen** showing the last known week, with
`Session expired` above them.

*Wrong:* the strip blanking out — that would mean it got gated on `hasSession`, which it
deliberately is not.

**How to force it.** There is a clean recipe, and this is the one state on the list worth
manufacturing, since a regression here would silently blank real data. `refresh()` keeps
`week` and `dayOffDates` and only flips `hasSession` on `.noSession`/`.sessionExpired`, and
`FlexClient` raises `.noSession` when `CookieVault.load()` comes back empty — so deleting
the keychain item simulates an expiry without disturbing the fetched week:

1. Open the popover and click **Flex re-sync**. Wait for `Synced HH:MM` and confirm the
   bars are on screen. (This step matters — the week must already be in memory.)
2. Delete the session item. It is a generic password on service
   `com.perso.flextimer.session`, account `flex` (`CookieVault.swift`, `defaultService`
   and `baseQuery`):

   ```bash
   security delete-generic-password -s com.perso.flextimer.session -a flex
   ```

   macOS may ask for keychain consent on the delete; that is expected and not part of what
   is being tested.

3. Click **Flex re-sync** again, *without quitting the app*. The popover should now read
   `Session expired` with the primary action changed to `Sign in to Flex…` — **and all five
   bars plus `Week OT` still on screen**, unchanged.

Undo by clicking `Sign in to Flex…` and signing in again, which writes a fresh item back.
**Do not quit the app before step 3** — a relaunch starts with no week in memory, so an
empty strip would then be *correct* and the test would silently prove nothing. That is the
failure mode that turns a green result into a false pass, which is worse than a skipped
step.

### A12. A day past the 10h scale — this is the one that verifies the clamp

A day of more than 10 hours net should draw a completely full bar: accent to the notch,
orange from the notch right up to the track's end cap, stopping dead there, flush with the
other bars' right edges, with the true figure (e.g. `11:55`) in the column beside it. Two
such days, 10h and 12h, look identical in the bar; that is intended saturation, not a
rendering fault.

*Wrong (this is exactly the bug the clamp fixes):* the orange tip continuing past where the
other tracks end — sticking out into the gap, or drawing under the hours figure so the
digits sit on an orange smear.

**How to force it, no 10-hour day required.** Note first that `dailyWorkHours` will *not*
do it: for an open day the bar's right edge works out to `(elapsed − break) / 10h`, with the
target cancelling out, so changing the target moves the notch without moving the bar's end.
What does work is a back-dated manual start, which the popover offers directly. Do this
**before clocking in** for the day (the "Or set it manually" row only appears when there is
no record yet), and late enough that the bar has passed the scale. The threshold: the
open-day bar ends at `(elapsed − break) / 10h`, so with a 00:05 start it saturates once the
clock passes **11:05**; do it after 11:10 to be clear of it.

- In the popover, set the `Started at` picker to `00:05` and click **Set**.
- Today's row should now show a completely full, saturated bar.
- **The figure beside it is *not* midnight-to-now.** `netWorked` deducts the lunch already
  elapsed, so at 13:00 the column reads about **`11:55`**, an hour less than the 12:55 on
  the wall clock. That hour is the 11:30–12:30 break, correctly removed. Do not report the
  missing hour as a bug; earlier than 11:30 no lunch has elapsed yet and the figure will
  match the wall clock instead.

Undo it afterwards, substituting today's date (the key format is
`SettingsStore.key(for:)`):

```bash
defaults delete com.perso.flextimer manualStart-$(date +%Y-%m-%d)
```

### A12b. The degenerate case at a 10h target — optional, and worth seeing once

With the manual start from A12 still in place, raise the daily target past the scale:

```bash
# Same caution as A8 — save the current value before overwriting it:
defaults read com.perso.flextimer dailyWorkHours    # note it, or "does not exist"
defaults write com.perso.flextimer dailyWorkHours -float 10.0
# relaunch, look, then undo — restore the old value, or delete only if there was none:
defaults write com.perso.flextimer dailyWorkHours -float <old value>
defaults delete com.perso.flextimer dailyWorkHours
```

The notch should pin to the track's right end cap and the orange segment should vanish
entirely — the row shows a full accent bar and no overtime colour at all, even though the
figure beside it is well past 10 hours. That is the joint clamp hitting zero remaining
width, and it is the visible cost of setting a target at or above the strip's 10h scale.

*Wrong:* orange drawn past the end cap (the clamp is not holding at its boundary), or the
notch floating in the middle of the track.

Undo both defaults when done.

### Two things about the strip that are not bugs

Recorded here so neither is filed twice:

- **A weekend record counts toward `Week OT` but has no row.** The strip is Mon–Fri only,
  so a Saturday shift adds to the total printed directly beneath the rows while appearing
  in none of them. That is `WeekSummary.compute`'s documented, test-pinned choice
  (`testWeekendRecordCountsInTheTotalButHasNoRow`) — but it is the one way the rows can
  visibly fail to sum to the total below them.
- **A day off draws its notch at x=0.** Its target is 0, so the tick lands at the track's
  left cap and reads as a small mark there. Intended.

---

# Part B — the Linux tray

**Not runnable on the author's Mac.** This part needs a coworker's Linux desktop. Run the
steps in order; B6, B7 and B9 are conditional or optional and say so.

### B1. Install and launch

Install the way users do: **from the tarball, not from a checkout.** The repo's `linux/`
has no `kaltoe-core` — that is a build artefact — so `./install.sh` run there aborts on its
first argument, for a reason unrelated to anything under test, and never exercises the
shipped path at all.

On the Mac:

```bash
./scripts/build-linux.sh
scp build/kaltoe-timer-linux-x86_64.tar.gz <linux-box>:
```

On the Linux box:

```bash
tar -xzf kaltoe-timer-linux-x86_64.tar.gz
cd kaltoe-timer-linux && ./install.sh
pkill -f kaltoe-tray.py; ~/.local/share/kaltoe-timer/kaltoe-tray.py
```

Run the tray in the foreground the first time, so you see stderr.

*Right:* `install.sh` ends with `Installed to …`, the tray icon appears, and
`ls ~/.local/share/kaltoe-timer/` lists **`kaltoe_rows.py`** next to `kaltoe-tray.py`.

*Wrong:* `install.sh` dies on `cp: cannot stat 'kaltoe_rows.py'`, or the tray dies with
`ModuleNotFoundError: No module named 'kaltoe_rows'` — the *tarball* did not stage the
module, which the drift guard in `scripts/build-linux.sh` should have caught at build time.
Nothing else in this list can be checked until that is fixed.

### B2. Open the menu while clocked in — check the order, top to bottom

*Right:* `Started HH:MM` / `Leave at HH:MM` / (caption row, only on a shortened day) /
`Time left H:MM:SS` / a separator / **five** day rows Mon–Fri / a separator /
`Week OT +H:MM / 12:00` / a separator / `Synced …`.

*Wrong:* day rows above `Time left`; four rows or six; a separator immediately followed by
another separator (an empty block); the week rows appearing twice.

### B3. Read the day rows

*Right:* `Mon   8:35   +0:35` — three spaces between fields. Overtime appears **only** when
non-zero. The row for the day you are **currently clocked in on** ends `· on the clock`,
with a middle dot (·), not `-` or `*` — and after you clock out that row correctly loses
the marker, so a menu opened at 19:30 having clocked out shows no marked row at all. That
is right, not a bug. A Flex day off reads `Wed   off`. A weekday you have not worked is the
bare label alone: `Fri`.

*Wrong:* `Thu   0:00` for a day you never worked — that would mean "no record" was
conflated with "worked zero minutes"; report it, it is a bug, not cosmetics. Also wrong:
`+0:00` on any row; a literal `<b>` or other markup; single-spaced fields
(`Mon 8:35 +0:35`) — that one is the panel collapsing whitespace, cosmetic, but say so,
because the columns were the point.

### B4. Cross-check against macOS for the same week

Mac app popover open side by side.

*Right:* every row's hours figure is identical to the macOS row — both are truncated to the
whole minute, so there is no rounding slack. The visible rows' overtimes sum to `Week OT`
**unless you worked a Saturday or Sunday**, which counts in the total and deliberately has
no row. One expected difference, not a defect: for a weekday with no record macOS draws a
`·` placeholder where the tray shows the bare label with nothing after it.

*Wrong:* any row off by a minute or more, or a row that disagrees in sign or label.

### B5. The `/ 12:00` denominator

*Right:* `Week OT +1:45 / 12:00` (or your configured cap).

*Wrong:* a bare `Week OT +1:45` with no denominator — the installed `kaltoe-core` is an
older build without `weekOvertimeCap`; re-run `install.sh` after `./scripts/build-linux.sh`.
Also wrong: a trailing `/` with nothing after it.

### B6. The caption row — conditional: only exists when today's target is reduced

Naturally reachable on the **last Friday of the month** — **2026-07-31**, then
**2026-08-28** — with `familyDayEarlyLeaveHours` at its default 2h, or on any day with
approved Flex time off.

*Right:* one grey row reading `Target 6:00 · family day` (or `… · time off`, or
`… · family day, time off`), sitting slightly indented under `Leave at`.

*Wrong:* a hyphen where the middle dot belongs, or any wording that differs from the macOS
popover's caption on the same day — the string is composed once in Swift
(`TargetNote.compose`) and passed through, so a difference means someone rebuilt it in
Python. Also wrong: the row present on an ordinary full-length day.

**Cannot be forced.** `targetNote` depends on the real date and on real Flex time-off data;
there is no local setting that fabricates it. **Do not move the system clock to fake it** —
Flex sync and session expiry both read the system clock, and you would poison the day's
records. If today is not a shortened day, skip this step and check it on the last Friday.

**One deliberate divergence you will see on that day, needing your judgement rather than a
bug report.** The daemon gates `summary` on `hasSession` only, so on a shortened day
`targetNote` is on the wire *before* you clock in. macOS shows `Not clocked in yet` and no
caption (its caption lives inside the `if let today` branch); Linux will show the indented
`Target 6:00 · family day` row alone, with no `Started`/`Leave at` above it. That was
shipped on purpose — "your target is 6:00 today" is most useful *before* you clock in.
What may look wrong is narrower than the row itself: the two-space indent at
`kaltoe-tray.py:362` subordinates the caption to a `Leave at` row that is not rendered in
that state. If it looks ugly on a real panel, the fix is to drop those two spaces when
`started` is absent — nothing else. Visible on the last Friday before clock-in if you want
to see it.

### B7. Forcing the cap, to prove the denominator is live — optional; skip if it does not work

There is **no `defaults write` on Linux**. The daemon's settings live in
`~/.config/kaltoe-core.plist` — the file the README's uninstall line deletes
(`linux/README-linux.md:138`) — because swift-corelibs-foundation backs
`UserDefaults.standard` with a plist named after the executable.

```bash
pkill -f kaltoe-tray.py
cp ~/.config/kaltoe-core.plist ~/.config/kaltoe-core.plist.bak 2>/dev/null || true
python3 - <<'PY'
import plistlib, pathlib
p = pathlib.Path.home() / ".config" / "kaltoe-core.plist"
d = plistlib.loads(p.read_bytes()) if p.exists() else {}
d["weeklyOvertimeCapHours"] = 3.0
p.write_bytes(plistlib.dumps(d))
PY
~/.local/share/kaltoe-timer/kaltoe-tray.py &
```

*Right:* the row now reads `… / 3:00`.

Undo: `mv ~/.config/kaltoe-core.plist.bak ~/.config/kaltoe-core.plist` (or `rm` the file if
there was no backup), then relaunch the tray.

**Caveat that cannot be stood behind from macOS:** whether corelibs-Foundation picks up a
plistlib-written XML plist for this domain, and whether it re-reads it after the daemon
starts. If the row still says `12:00` after the relaunch, that *is* the answer — the
mechanism does not work; do not chase it. The denominator's value is already pinned by
`HeadlessStateTests` (`weekOvertimeCap == 12 * 3600`), so this step is confirmation, not
coverage.

### B8. Signed-out clear-down

Menu → **Sign out**. Safe and reversible.

*Right:* the caption, all five day rows and **both** separators disappear together, along
with `Started` / `Leave at` / `Time left` / `Week OT`; the status row reads `Signed out`;
the menu shows `Sign in to Flex…`.

*Wrong:* any day row still showing last week's figures; a leftover pair of adjacent
separator lines with nothing between them.

Undo: **Sign in to Flex…** and log in normally.

### B9. Fresh-Monday gate — only checkable on a Monday before you clock in

*Right:* signed in, no hours yet this week → **no day rows and no separators at all**,
matching macOS, which hides its strip in the same state.

*Wrong:* five bare labels `Mon Tue Wed Thu Fri` with no figures, or a lone pair of
separators around nothing.

**Cannot be forced mid-week.** The nearest safe equivalent is B8 (rows absent), and the
gate itself is asserted by a stub harness during development — so this step is a sanity
check, not the only evidence.

### B10. Core death clear-down

```bash
pkill -f kaltoe-core
```

*Right:* the status row becomes `core stopped — use Restart core`, a `Restart core` item
appears, and every added row (caption, five days, both separators, `Week OT`) is gone.

*Wrong:* stale day rows still visible behind a dead core.

Undo: menu → **Restart core**.

### B11. Plasma only — reopen the menu three or four times over a couple of minutes while clocked in

*Right:* `Time left` and today's row move.

*Wrong:* the day figures frozen at their first values while the tray icon's countdown
advances — that is Plasma's per-item cache, the same pathology `_set_text_icon` already
works around for the icon, and it would need the same never-reused-name trick for menu
items.

### B12. stderr

*Right:* nothing new.

*Wrong:* `Gtk-CRITICAL` / `Gtk-WARNING` lines mentioning menu items appearing when the menu
is opened.

### One thing about the tray rows that is not a bug

**Stale text survives on hidden rows.** `set_visible(False)` does not clear a label, so a
host that mishandled visibility would surface last week's figures rather than blanks. This
is identical to the behaviour of the four pre-existing detail rows, so it was left alone.
B8 and B10 are where it would show up if a host does mishandle it.

---

# Optional investigation — could the tray rows be bars after all?

**Not required for sign-off.** The figures are correct either way; this only decides
whether a bar could join them. Record what you find if you happen to look.

The tray rows carry text with a signed overtime figure instead of a drawn bar. The reason
given in `linux/kaltoe_rows.py` is that DBusMenu carries no custom widgets — true, but by
itself that does not close the question, and the honest version of the argument is narrower:

**`icon-data` does travel.** It is a standard `com.canonical.dbusmenu` item property holding
raw PNG bytes, so a per-row bar rendered to a small PNG and attached via
`Gtk.ImageMenuItem` could in principle survive to the panel. The decision therefore rests
on **panel icon sizing**, not on the transport: GNOME's appindicator extension draws
menu-item icons at roughly 16px, and a row whose icon is sized to ~16 square leaves nowhere
for a bar to be long. Note that a 16px-*tall* but *wide* bar would resolve 35 versus 70
minutes perfectly well — so the objection is the sizing a panel imposes, not resolution in
principle. (An earlier draft also cited Plasma's pixmap cache; that argument is
**withdrawn** — the cache is keyed by icon *name*, which is exactly why `_set_text_icon`
needs never-reused names, whereas `icon-data` is nameless raw bytes and would not hit it.)

Two findings would reopen the decision, in increasing order of consequence:

1. **A custom widget visibly rendering.** Add a `Gtk.MenuItem`, `remove()` its label child
   and `add()` a `Gtk.DrawingArea` with a `draw` handler that fills a coloured rectangle;
   append it to the tray menu. If that rectangle appears in the panel menu, the constraint
   is simply false and the bars-versus-figures decision reopens outright. Expected: an
   empty or zero-height row — the panel is a different process and never sees your `draw`
   callback.

2. **The protocol carrying more than assumed.** Find the item's menu object and dump the
   layout:

   ```bash
   busctl --user list | grep -i StatusNotifierItem     # find the service name
   gdbus call --session --dest <service> --object-path /MenuBar \
     --method com.canonical.dbusmenu.GetLayout 0 -1 '[]'
   ```

   Expected per-item properties: only `type`, `label`, `enabled`, `visible`,
   `children-display`, and for some items `icon-name` / `icon-data` / `toggle-type` /
   `toggle-state`. Anything widget-shaped in that dictionary disproves the claim.

The falsifiable version is the conjunction: if you find **both** (a) `icon-data` present in
`GetLayout` and (b) an `ImageMenuItem`'s pixbuf visibly rendering at a usable size in the
panel menu, then bars are technically reachable and the choice reopens.
