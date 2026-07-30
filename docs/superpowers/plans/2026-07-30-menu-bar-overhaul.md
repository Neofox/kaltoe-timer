# Menu Bar Label Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 칼퇴타이머 menu bar label's three-symbol, two-alarm-colour design with an eight-glyph set, a day-long colour spectrum, and a user-chosen Ring or Track progress geometry — without changing one byte of the NDJSON wire the Linux tray reads.

**Architecture:** All appearance logic is pure and lives in `KaltoeCore` (`labelGlyph`, `labelText`, `LabelPhase`, `LabelPalette`, `dayProgress`), so it is unit-testable and free of AppKit. `FlexTimer` holds only the `ImageRenderer` drawing. The existing `menuBarText`/`iconName` properties are left byte-identical and the new Mac-only properties sit beside them, because `linux/kaltoe-tray.py` depends on today's exact symbol names and `BREAK`/`OT` prefixes.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI + AppKit (`MenuBarExtra`, `ImageRenderer`), XCTest.

## Global Constraints

- **`KaltoeCore` must compile for Linux.** It may not import SwiftUI or AppKit. Colours crossing the module boundary are plain `Double` components, never `Color`.
- **The NDJSON wire is frozen.** `DisplayState.menuBarText`, `DisplayState.iconName` and every `StatusLine` field keep their exact current output for every state. `Sources/KaltoeDaemon/` and `linux/kaltoe-tray.py` are not edited by this plan.
- `Package.swift` keeps `platforms: [.macOS("26.0")]` as a **string**, not `.macOS(.v26)` — the Linux build image's SwiftPM has no `.v26` case.
- Test conventions: XCTest, `@testable import KaltoeCore`, the global `d(_ y:_ mo:_ da:_ h:_ mi:)` Asia/Seoul date helper and global `let rules = WorkRules()` both defined in `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`.
- Run tests with plain `swift test`. No temp-keychain workaround is needed.
- In array literals of `Double` (e.g. `StrokeStyle` dash arrays), write the **leading** element with a decimal point — `[2.0, 2]`, not `[2, 2]` — per commit `94d46a5`.
- Commit messages: lowercase conventional prefix (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`).
- Reference spec: `docs/superpowers/specs/2026-07-30-menu-bar-overhaul-design.md`.

---

## File Structure

| File                                                                | Responsibility                                                                | Task |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ---- |
| `Sources/KaltoeCore/WorkCalculator.swift`                           | add `dayProgress`                                                             | 1    |
| `Sources/KaltoeCore/DisplayState.swift`                             | `.overtime` gains `clockedIn`; add `labelGlyph`, `labelText`                  | 2, 3 |
| `Sources/KaltoeCore/LabelAppearance.swift`                          | **new** — `LabelGeometry`, `RGBA`, `ColourPair`, `LabelPhase`, `LabelPalette` | 4    |
| `Sources/KaltoeCore/MenuLabelStyle.swift`                           | **deleted**                                                                   | 6    |
| `Sources/KaltoeCore/SettingsStore.swift`                            | add `labelGeometry`; remove `highContrastOnInactiveDisplays`                  | 5, 7 |
| `Sources/FlexTimer/MenuBarLabel.swift`                              | rewritten — one render path, Ring + Track                                     | 6    |
| `Sources/FlexTimer/AppState.swift`                                  | publish `labelProgress`, `labelGeometry`; drop high contrast                  | 6, 7 |
| `Sources/FlexTimer/FlexTimerApp.swift`                              | new label arguments                                                           | 6    |
| `Sources/FlexTimer/LabelGeometryRow.swift`                          | **new** — the segmented picker                                                | 7    |
| `Sources/FlexTimer/MenuBarView.swift`                               | swap `highContrastRow` for `LabelGeometryRow`                                 | 7    |
| `Tests/KaltoeCoreTests/DisplayStateTests.swift`                     | **new** — glyph and text mapping                                              | 3    |
| `Tests/KaltoeCoreTests/LabelAppearanceTests.swift`                  | **new** — phase and palette                                                   | 4    |
| `Tests/KaltoeCoreTests/MenuLabelStyleTests.swift`                   | **deleted**                                                                   | 6    |
| `README.md`, `docs/superpowers/2026-07-30-menu-bar-verification.md` | docs + hardware checklist                                                     | 8    |

Tasks 1–5 are additive and each leaves the tree compiling. Task 6 is the breaking swap (label signature, deleted style enum). Task 7 removes the retired setting. Task 8 is documentation.

---

### Task 1: `WorkCalculator.dayProgress`

The fill's single source of truth. Pure, no dependencies on any other task.

**Files:**

- Modify: `Sources/KaltoeCore/WorkCalculator.swift` (append inside `enum WorkCalculator`, after `timeLeft` at `:35-37`)
- Test: `Tests/KaltoeCoreTests/WorkCalculatorTests.swift` (append)

**Interfaces:**

- Consumes: existing `WorkCalculator.leaveTime(clockIn:rules:timeOff:)`, `WorkRules`.
- Produces: `WorkCalculator.dayProgress(clockIn: Date, now: Date, rules: WorkRules, timeOff: TimeInterval = 0) -> Double`, always finite and in `0...1`. Tasks 4 and 6 consume it.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`, inside `final class WorkCalculatorTests`:

```swift
    // MARK: dayProgress

    // Canonical day: clock in 08:59 → leave 17:59, a 9h span (8h target + 1h break).
    // 13:29 is 4h30 in, exactly half.
    func testDayProgressIsHalfwayAtMidSpan() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 13, 29), rules: rules),
                       0.5, accuracy: 0.0001)
    }

    /// The denominator is the whole clock-in→leave span, not the 8h target. Dividing
    /// by the target alone would read 1.0 here, an hour before you may leave.
    func testDayProgressAtTargetButNotLeaveTimeIsNotComplete() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 16, 59), rules: rules),
                       8.0 / 9.0, accuracy: 0.0001)
    }

    func testDayProgressIsZeroAtClockIn() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 8, 59), rules: rules), 0)
    }

    func testDayProgressClampsBeforeClockInAndPastLeaveTime() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 7, 0), rules: rules), 0)
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 8, 59),
                                                 now: d(2026, 7, 6, 23, 0), rules: rules), 1)
    }

    /// Family day (last Friday of the month) cuts the target to 6h; the break
    /// survives because 6h is still over half a day, so the span is 7h. 12:30 is
    /// 3h30 in.
    func testDayProgressUsesTheFamilyDayShortenedSpan() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 31, 9, 0),
                                                 now: d(2026, 7, 31, 12, 30), rules: rules),
                       0.5, accuracy: 0.0001)
    }

    /// 4h of time off drops the target to 4h, which is *not* over half a day, so
    /// `breakDuration` yields no lunch and the span is 4h — not 5h. Deriving the
    /// span from `leaveTime` is what inherits that rule.
    func testDayProgressLosesTheBreakOnAHalfDay() {
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 11, 0), rules: rules,
                                                 timeOff: 4 * 3600),
                       0.5, accuracy: 0.0001)
    }

    /// Hostile settings reach here through `SettingsStore.rules`. A zero span
    /// would divide to ±inf and a non-finite target to NaN; both must yield 0,
    /// because the renderer may never see one.
    func testDayProgressIsZeroWhenTheSpanCollapses() {
        var zero = rules
        zero.dailyWork = 0
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 14, 0), rules: zero), 0)
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 14, 0), rules: rules,
                                                 timeOff: 8 * 3600), 0)
    }

    func testDayProgressIsZeroForANonFiniteTarget() {
        var wild = rules
        wild.dailyWork = .infinity
        XCTAssertEqual(WorkCalculator.dayProgress(clockIn: d(2026, 7, 6, 9, 0),
                                                 now: d(2026, 7, 6, 14, 0), rules: wild), 0)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WorkCalculatorTests`
Expected: compile failure — `type 'WorkCalculator' has no member 'dayProgress'`.

- [ ] **Step 3: Implement `dayProgress`**

In `Sources/KaltoeCore/WorkCalculator.swift`, immediately after `timeLeft` (`:35-37`):

```swift
    /// How far the day has run from clock-in to leave time, as `0...1`.
    ///
    /// The denominator is the **whole** clock-in→leave-time span — `target + break` —
    /// taken from `leaveTime` rather than re-added here. Dividing by the target alone
    /// would reach 1.0 a full hour early, and deriving the span from `leaveTime`
    /// inherits `breakDuration`'s half-day rule instead of duplicating it, so a 4h
    /// time-off day scales to its real 4h span and not a phantom 5h one.
    ///
    /// Measures distance to leave time, not work completed, so it keeps advancing
    /// through lunch instead of stalling for an hour. That is what keeps the menu
    /// bar's fill monotonic while the countdown beside it switches from
    /// counting-to-lunch to counting-to-leave.
    ///
    /// Total by construction, like `StatusLine.secondsFlooredToMinute`: `dailyWork`
    /// comes from a raw `Double` in `UserDefaults` that the README documents a
    /// `defaults write` for. A collapsed span (`dailyWorkHours 0`, or time off at or
    /// above the target — `dailyTarget` floors at zero and `breakDuration` then
    /// yields no lunch either) and a non-finite one both return 0 rather than
    /// handing `±inf` or `NaN` to the renderer.
    public static func dayProgress(clockIn: Date, now: Date, rules: WorkRules,
                                   timeOff: TimeInterval = 0) -> Double {
        let span = leaveTime(clockIn: clockIn, rules: rules, timeOff: timeOff)
            .timeIntervalSince(clockIn)
        guard span.isFinite, span > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(clockIn)
        guard elapsed.isFinite else { return 0 }
        return min(1, max(0, elapsed / span))
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WorkCalculatorTests`
Expected: PASS, all eight new tests plus the pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/WorkCalculator.swift Tests/KaltoeCoreTests/WorkCalculatorTests.swift
git commit -m "feat: dayProgress — the fill's single source of truth"
```

---

### Task 2: `.overtime` carries `clockedIn`

A settled day must be able to look settled. `computeDisplay` already derives this bit and throws it away.

**Files:**

- Modify: `Sources/KaltoeCore/DisplayState.swift` (`:23`, `:61-75`, `:78-87`)
- Test: `Tests/KaltoeCoreTests/StatusLineTests.swift` (append — the wire guard)

**Interfaces:**

- Consumes: nothing new.
- Produces: `case overtime(today: TimeInterval, clockedIn: Bool)`. Tasks 3, 4 and 6 pattern-match it.

- [ ] **Step 1: Write the failing wire-guard test**

Append to `Tests/KaltoeCoreTests/StatusLineTests.swift`, inside its test class:

```swift
    /// The NDJSON wire is frozen. `kaltoe-tray.py` maps exactly these three symbol
    /// names in `ICON_BASE` and falls back to a generic timer for anything else, its
    /// `LABEL_GUIDE` is sized from the `OT ` prefix, and `render_text_icon` stacks
    /// the label at the first space — which on KDE is the only phase signal there is,
    /// since that tray renders the text alone with no glyph. The Mac's expressive
    /// glyphs and prefix-free text live on `labelGlyph`/`labelText` instead. If this
    /// test fails, the Linux tray has regressed.
    func testWireTextAndIconAreUnchangedForEveryState() {
        let cases: [(DisplayState, String, String)] = [
            (.noSession, "—", "timer"),
            (.notClockedIn, "--:--", "timer"),
            (.toLunch(timeLeft: 80 * 60), "1:20", "fork.knife"),
            (.onBreak(timeLeft: 45 * 60), "BREAK 0:45", "cup.and.saucer"),
            (.counting(timeLeft: 154 * 60), "2:34", "timer"),
            (.overtime(today: 3600, clockedIn: true), "OT +1:00", "timer"),
            (.overtime(today: 3600, clockedIn: false), "OT +1:00", "timer"),
            (.overtime(today: -20 * 60, clockedIn: false), "OT -0:20", "timer"),
        ]
        for (state, text, icon) in cases {
            XCTAssertEqual(state.menuBarText, text, "menuBarText for \(state)")
            XCTAssertEqual(state.iconName, icon, "iconName for \(state)")
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter StatusLineTests`
Expected: compile failure — `.overtime` has no `clockedIn` argument.

- [ ] **Step 3: Add the associated value and thread it through**

In `Sources/KaltoeCore/DisplayState.swift`, change the case at `:23`:

```swift
    case overtime(today: TimeInterval, clockedIn: Bool)   // overtime worked today; negative if short
```

In `computeDisplay`, the `clockedIn` local already exists at `:63`. Change only the final return (`:75`):

```swift
        return MenuDisplay(state: .overtime(today: todayOvertime, clockedIn: clockedIn),
                           urgency: urgency)
```

In `menuBarText` (`:85`), ignore the new value so the wire output is untouched:

```swift
        case .overtime(let today, _): return "OT " + Formatting.signedHM(today)
```

`iconName` needs no change: `case .noSession, .notClockedIn, .counting, .overtime:` matches an enum case with associated values without binding them.

- [ ] **Step 4: Fix every remaining call site the compiler flags**

Run: `swift build 2>&1 | grep -E "error:"`

Fix each reported construction or pattern-match by supplying/ignoring `clockedIn`. Expect hits in `Sources/FlexTimer/MenuBarView.swift` (the `if case .onBreak` at `:74` is unaffected) and in test files that build `.overtime` directly. Where a test constructs it, pass `clockedIn: true` unless the test is specifically about a completed day.

Run: `swift build` until clean, then `swift test 2>&1 | grep -E "error:"` and repeat for the test targets.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, including the new `testWireTextAndIconAreUnchangedForEveryState`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: .overtime carries clockedIn, so a settled day can look settled"
```

---

### Task 3: `labelGlyph` and `labelText`

The Mac-only half of the appearance mapping, parallel to the frozen wire properties.

**Files:**

- Modify: `Sources/KaltoeCore/DisplayState.swift` (append after `iconName`)
- Test: `Tests/KaltoeCoreTests/DisplayStateTests.swift` (**create** — no such file exists today)

**Interfaces:**

- Consumes: `DisplayState` incl. `.overtime(today:clockedIn:)` from Task 2; `Formatting.hm`, `Formatting.signedHM`.
- Produces: `DisplayState.labelGlyph -> String`, `DisplayState.labelText -> String`. Task 6 reads both.

- [ ] **Step 1: Write the failing tests**

Create `Tests/KaltoeCoreTests/DisplayStateTests.swift`:

```swift
import XCTest
@testable import KaltoeCore

final class DisplayStateTests: XCTestCase {
    func testLabelGlyphPerState() {
        XCTAssertEqual(DisplayState.noSession.labelGlyph, "zzz")
        XCTAssertEqual(DisplayState.notClockedIn.labelGlyph, "timer")
        XCTAssertEqual(DisplayState.toLunch(timeLeft: 80 * 60).labelGlyph, "fork.knife")
        XCTAssertEqual(DisplayState.onBreak(timeLeft: 45 * 60).labelGlyph, "cup.and.saucer")
    }

    /// The countdown turns into a walking figure inside the last half hour. Keyed
    /// off `timeLeft` directly, not off `Urgency`, which no longer drives appearance.
    func testCountingGlyphSwitchesToAFigureInTheLastHalfHour() {
        XCTAssertEqual(DisplayState.counting(timeLeft: 31 * 60).labelGlyph, "timer")
        XCTAssertEqual(DisplayState.counting(timeLeft: 30 * 60).labelGlyph, "figure.walk")
        XCTAssertEqual(DisplayState.counting(timeLeft: 60).labelGlyph, "figure.walk")
    }

    func testOvertimeGlyphDistinguishesTheCelebrationTheClockAndASettledDay() {
        XCTAssertEqual(DisplayState.overtime(today: 0, clockedIn: true).labelGlyph,
                       "figure.walk.departure")
        XCTAssertEqual(DisplayState.overtime(today: 59, clockedIn: true).labelGlyph,
                       "figure.walk.departure")
        XCTAssertEqual(DisplayState.overtime(today: 60, clockedIn: true).labelGlyph, "flame")
        XCTAssertEqual(DisplayState.overtime(today: 3600, clockedIn: true).labelGlyph, "flame")
    }

    /// `checkmark` means settled, not target met — clocking out short still lands
    /// in `.overtime`, with a negative figure and a ring that visibly did not fill.
    func testClockedOutAlwaysReadsAsSettled() {
        XCTAssertEqual(DisplayState.overtime(today: 3600, clockedIn: false).labelGlyph, "checkmark")
        XCTAssertEqual(DisplayState.overtime(today: 0, clockedIn: false).labelGlyph, "checkmark")
        XCTAssertEqual(DisplayState.overtime(today: -20 * 60, clockedIn: false).labelGlyph,
                       "checkmark")
    }

    /// The BREAK and OT words are gone — the glyph carries the phase. They stay on
    /// `menuBarText` for the Linux tray, which has no glyph.
    func testLabelTextDropsTheWordPrefixes() {
        XCTAssertEqual(DisplayState.onBreak(timeLeft: 45 * 60).labelText, "0:45")
        XCTAssertEqual(DisplayState.overtime(today: 3600, clockedIn: true).labelText, "+1:00")
        XCTAssertEqual(DisplayState.overtime(today: -20 * 60, clockedIn: false).labelText, "-0:20")
    }

    func testLabelTextForTheQuietStates() {
        XCTAssertEqual(DisplayState.noSession.labelText, "")
        XCTAssertEqual(DisplayState.notClockedIn.labelText, "--:--")
        XCTAssertEqual(DisplayState.toLunch(timeLeft: 80 * 60).labelText, "1:20")
        XCTAssertEqual(DisplayState.counting(timeLeft: 154 * 60).labelText, "2:34")
    }

    /// 자유! occupies exactly the minute `signedHM` would render as "+0:00", so it
    /// displaces no reading at all. It requires being on the clock.
    func testJayuOccupiesTheFirstMinuteOfOvertimeOnly() {
        XCTAssertEqual(DisplayState.overtime(today: 0, clockedIn: true).labelText, "자유!")
        XCTAssertEqual(DisplayState.overtime(today: 59, clockedIn: true).labelText, "자유!")
        XCTAssertEqual(DisplayState.overtime(today: 60, clockedIn: true).labelText, "+0:01")
        XCTAssertEqual(DisplayState.overtime(today: 30, clockedIn: false).labelText, "+0:00")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter DisplayStateTests`
Expected: compile failure — `value of type 'DisplayState' has no member 'labelGlyph'`.

- [ ] **Step 3: Implement both properties**

In `Sources/KaltoeCore/DisplayState.swift`, append after `iconName` (`:89-95`):

```swift
    /// Menu-bar-only glyph, deliberately parallel to `iconName` rather than
    /// replacing it. `iconName` is the daemon's NDJSON contract: `kaltoe-tray.py`
    /// maps exactly `timer`, `fork.knife` and `cup.and.saucer` in `ICON_BASE` and
    /// falls back to a generic timer for anything else, so putting these names on the
    /// wire would silently flatten the lunch phases on Linux.
    public var labelGlyph: String {
        switch self {
        case .noSession: return "zzz"
        case .notClockedIn: return "timer"
        case .toLunch: return "fork.knife"
        case .onBreak: return "cup.and.saucer"
        case .counting(let left):
            return left <= Self.warningThreshold ? "figure.walk" : "timer"
        case .overtime(let today, let clockedIn):
            // Settled outranks everything: a day you have clocked out of reads as
            // closed even if it ended short, in which case the fill did not finish
            // and the figure is signed.
            guard clockedIn else { return "checkmark" }
            return today < 60 ? "figure.walk.departure" : "flame"
        }
    }

    /// Menu-bar-only text: `menuBarText` minus the `BREAK`/`OT` word prefixes, which
    /// `labelGlyph` now carries. The prefixes stay on the wire because on KDE the
    /// tray renders that text alone with no glyph at all, making them its only phase
    /// signal.
    public var labelText: String {
        switch self {
        case .noSession: return ""
        case .notClockedIn: return "--:--"
        case .toLunch(let left), .onBreak(let left), .counting(let left):
            return Formatting.hm(left)
        case .overtime(let today, let clockedIn):
            // 자유! for exactly the span `signedHM` would render "+0:00", so nothing
            // is displaced. Not a state, an event or a timer — just what this
            // property returns for one minute, which is why it cannot get stuck on,
            // fire repeatedly under the 1s tick, or fire retroactively on a launch
            // at 20:00.
            if clockedIn, today < 60 { return "자유!" }
            return Formatting.signedHM(today)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DisplayStateTests`
Expected: PASS, all seven tests.

- [ ] **Step 5: Run the whole suite, confirming the wire guard still holds**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/KaltoeCore/DisplayState.swift Tests/KaltoeCoreTests/DisplayStateTests.swift
git commit -m "feat: labelGlyph and labelText — the Mac label's own vocabulary"
```

---

### Task 4: `LabelAppearance.swift` — phase and palette

**Files:**

- Create: `Sources/KaltoeCore/LabelAppearance.swift`
- Test: `Tests/KaltoeCoreTests/LabelAppearanceTests.swift` (**create**)

**Interfaces:**

- Consumes: `MenuDisplay`, `DisplayState`, `Urgency`.
- Produces, all read by Tasks 5, 6 and 7:
  - `LabelGeometry: String, CaseIterable, Sendable` with `.ring`, `.track`
  - `RGBA(red:green:blue:alpha:)` and `RGBA(_ hex: UInt32, alpha:)`, fields `red`/`green`/`blue`/`alpha`
  - `ColourPair(light: RGBA, dark: RGBA)`
  - `LabelFill` with `.pair(ColourPair)`, `.systemOrange`, `.systemRed`
  - `LabelPhase(_ display: MenuDisplay)` with `.idle`/`.working`/`.overtime`/`.atLimit`/`.settled`
  - `LabelPalette.resolve(progress: Double, phase: LabelPhase) -> LabelPalette.Colours`, whose fields are `fill: LabelFill`, `glyphTint: LabelFill?`, `track: ColourPair`, `dashed: Bool`. Note `fill` and `glyphTint` are `LabelFill`, **not** `ColourPair` — only `track` is a bare pair.

- [ ] **Step 1: Write the failing tests**

Create `Tests/KaltoeCoreTests/LabelAppearanceTests.swift`:

```swift
import XCTest
@testable import KaltoeCore

final class LabelAppearanceTests: XCTestCase {

    // MARK: LabelPhase

    func testIdlePhases() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .noSession, urgency: .normal)), .idle)
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .notClockedIn, urgency: .normal)), .idle)
    }

    func testWorkingPhases() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .toLunch(timeLeft: 60), urgency: .normal)),
                       .working)
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .onBreak(timeLeft: 60), urgency: .normal)),
                       .working)
        // Still `.working` at critical urgency: inside the last ten minutes the
        // spectrum is already amber because of where it sits in the day, and colour
        // no longer keys off Urgency at all.
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .counting(timeLeft: 60), urgency: .critical)),
                       .working)
    }

    func testOvertimeSeparatesTheLimitFromOrdinaryOvertime() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .overtime(today: 3600, clockedIn: true),
                                              urgency: .warning)), .overtime)
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .overtime(today: 3600, clockedIn: true),
                                              urgency: .critical)), .atLimit)
    }

    /// `clockedIn` is authoritative, not urgency. `hasReachedWeeklyCap` returns
    /// critical off the clock too, so an urgency-first mapping would paint a
    /// finished day red.
    func testAClockedOutDayIsSettledEvenAtTheWeeklyCap() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .overtime(today: 3600, clockedIn: false),
                                              urgency: .critical)), .settled)
    }

    // MARK: LabelPalette

    func testSpectrumHitsEachStopExactly() {
        XCTAssertEqual(LabelPalette.spectrum(0), LabelPalette.stops[0])
        XCTAssertEqual(LabelPalette.spectrum(1.0 / 3.0), LabelPalette.stops[1])
        XCTAssertEqual(LabelPalette.spectrum(2.0 / 3.0), LabelPalette.stops[2])
        XCTAssertEqual(LabelPalette.spectrum(1), LabelPalette.stops[3])
    }

    func testSpectrumInterpolatesBetweenStops() {
        let mid = LabelPalette.spectrum(1.0 / 6.0)
        let a = LabelPalette.stops[0].dark, b = LabelPalette.stops[1].dark
        XCTAssertEqual(mid.dark.red, (a.red + b.red) / 2, accuracy: 0.0001)
        XCTAssertEqual(mid.dark.green, (a.green + b.green) / 2, accuracy: 0.0001)
        XCTAssertEqual(mid.dark.blue, (a.blue + b.blue) / 2, accuracy: 0.0001)
    }

    /// `dayProgress` already guarantees 0...1, but this is public surface and must
    /// not index out of bounds.
    /// `NaN` takes the guard; the infinities are handled by the clamp itself, so
    /// they land on the ends rather than being funnelled to the first stop.
    func testSpectrumClampsAndSurvivesNonFiniteInput() {
        XCTAssertEqual(LabelPalette.spectrum(-1), LabelPalette.stops[0])
        XCTAssertEqual(LabelPalette.spectrum(2), LabelPalette.stops[3])
        XCTAssertEqual(LabelPalette.spectrum(.nan), LabelPalette.stops[0])
        XCTAssertEqual(LabelPalette.spectrum(.infinity), LabelPalette.stops[3])
        XCTAssertEqual(LabelPalette.spectrum(-.infinity), LabelPalette.stops[0])
    }

    func testWorkingDayTakesItsFillFromTheSpectrum() {
        let c = LabelPalette.resolve(progress: 0, phase: .working)
        XCTAssertEqual(c.fill, .pair(LabelPalette.stops[0]))
        XCTAssertNil(c.glyphTint)
        XCTAssertFalse(c.dashed)
    }

    /// The alerting colours are the popover's own system colours, so the label and
    /// the week strip cannot drift into two different oranges.
    func testOvertimeAndLimitAreFlatAndTintTheGlyph() {
        let ot = LabelPalette.resolve(progress: 1, phase: .overtime)
        XCTAssertEqual(ot.fill, .systemOrange)
        XCTAssertEqual(ot.glyphTint, .systemOrange)

        let limit = LabelPalette.resolve(progress: 1, phase: .atLimit)
        XCTAssertEqual(limit.fill, .systemRed)
        XCTAssertEqual(limit.glyphTint, .systemRed)
    }

    /// Progress is ignored past target — the colour is discrete there, so a
    /// half-filled ring cannot come out orange-ish.
    func testOvertimeColourIgnoresProgress() {
        XCTAssertEqual(LabelPalette.resolve(progress: 0.2, phase: .overtime).fill,
                       LabelPalette.resolve(progress: 1, phase: .overtime).fill)
    }

    func testIdleIsDashedAndNeutral() {
        let c = LabelPalette.resolve(progress: 0, phase: .idle)
        XCTAssertTrue(c.dashed)
        XCTAssertEqual(c.fill, .pair(LabelPalette.neutral))
    }

    func testSettledIsNeutralAndNotDashed() {
        let c = LabelPalette.resolve(progress: 0.7, phase: .settled)
        XCTAssertFalse(c.dashed)
        XCTAssertEqual(c.fill, .pair(LabelPalette.neutral))
        XCTAssertNil(c.glyphTint)
    }

    func testHexInitialiserUnpacksChannels() {
        let c = RGBA(0x5aa9f8)
        XCTAssertEqual(c.red, 0x5a / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c.green, 0xa9 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c.blue, 0xf8 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c.alpha, 1)
    }

    func testGeometryIsStringBacked() {
        XCTAssertEqual(LabelGeometry(rawValue: "track"), .track)
        XCTAssertEqual(LabelGeometry.allCases, [.ring, .track])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter LabelAppearanceTests`
Expected: compile failure — `cannot find 'LabelPhase' in scope`.

- [ ] **Step 3: Create `LabelAppearance.swift`**

```swift
import Foundation

/// Menu bar label geometry — the user's choice between a closing arc and a filling
/// capsule. Both render as non-template images in every state, so neither dims on
/// the menu bar of an unfocused display; that is why the old high-contrast
/// preference no longer has anything to decide.
public enum LabelGeometry: String, CaseIterable, Sendable {
    case ring, track
}

/// An sRGB colour with alpha, as plain components.
///
/// Not `SwiftUI.Color`, deliberately: `KaltoeCore` builds for Linux, where SwiftUI
/// does not exist. `FlexTimer` maps these across the boundary.
public struct RGBA: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `RGBA(0x5aa9f8)` — the form the design spec writes its palette in, so the
    /// two can be compared by eye.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

/// One colour in both menu bar appearances. A spectrum stop is not a single colour:
/// the dark-bar values need darkening to hold contrast against a light bar.
public struct ColourPair: Equatable, Sendable {
    public var light: RGBA
    public var dark: RGBA

    public init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }
}

/// A fill the view resolves.
///
/// The `.system` cases exist so the label's alerting colours are the *same*
/// colours the popover already draws rather than tuned near-neighbours — the week
/// strip fills its over-target segment with the system orange
/// (`WeekBarRow.swift:70`). `KaltoeCore` cannot name a SwiftUI colour, so it names
/// the intent and `MenuBarLabel` resolves it.
public enum LabelFill: Equatable, Sendable {
    case pair(ColourPair)
    case systemOrange
    case systemRed
}

/// What the label's colour depends on. Narrower than `DisplayState` because colour
/// does not care *which* phase of the working day you are in, only that you are in
/// one — the spectrum handles the rest from progress.
public enum LabelPhase: Equatable, Sendable {
    case idle       // no session, or no record yet — nothing to colour
    case working    // on the clock, inside the day's target
    case overtime   // on the clock, past target, within both company limits
    case atLimit    // on the clock, past target, at the weekly cap or past the cutoff
    case settled    // clocked out

    /// `clockedIn` is authoritative for `.settled`; urgency only separates
    /// `.atLimit` from `.overtime` while you are still on the clock.
    ///
    /// Deliberately not urgency-first. `hasReachedWeeklyCap` yields `.critical`
    /// on or off the clock (`DisplayState.swift:65-66`), so keying `.atLimit` off
    /// urgency alone would paint a finished day red.
    public init(_ display: MenuDisplay) {
        switch display.state {
        case .noSession, .notClockedIn:
            self = .idle
        case .toLunch, .onBreak, .counting:
            self = .working
        case .overtime(_, let clockedIn):
            guard clockedIn else { self = .settled; return }
            self = display.urgency == .critical ? .atLimit : .overtime
        }
    }
}

/// The label's colours. Pure, so the whole palette is testable without AppKit.
public enum LabelPalette {
    public struct Colours: Equatable, Sendable {
        /// The arc stroke, or the capsule's filled portion.
        public var fill: LabelFill
        /// `nil` means the glyph follows the menu bar's own foreground colour.
        public var glyphTint: LabelFill?
        /// The unfilled remainder. Stays a `ColourPair` — the faint track has no
        /// system counterpart to match.
        public var track: ColourPair
        /// Draw the track dashed — used where there is no progress to show.
        public var dashed: Bool
    }

    /// Spectrum stops, equally spaced across `progress` 0…1: blue, teal, green,
    /// amber. Dark values are the approved mockup's; the light values are the same
    /// hues darkened to hold contrast on a light bar, and are the two-known-plus-
    /// derived starting point that the hardware pass adjusts.
    static let stops: [ColourPair] = [
        ColourPair(light: RGBA(0x1f6fd0), dark: RGBA(0x5aa9f8)),
        ColourPair(light: RGBA(0x1f8578), dark: RGBA(0x3fbfb0)),
        ColourPair(light: RGBA(0x4f9e3c), dark: RGBA(0x7fc06a)),
        ColourPair(light: RGBA(0xb0741a), dark: RGBA(0xe8a02a)),
    ]

    static let neutral = ColourPair(light: RGBA(0x6c6c74), dark: RGBA(0xa0a0a8))
    static let emptyTrack = ColourPair(light: RGBA(0x000000, alpha: 0.16),
                                       dark: RGBA(0xffffff, alpha: 0.22))

    public static func resolve(progress: Double, phase: LabelPhase) -> Colours {
        switch phase {
        case .idle:
            return Colours(fill: .pair(neutral), glyphTint: nil, track: emptyTrack, dashed: true)
        case .working:
            // No glyph tint through the working day: all the colour lives in the
            // fill and the glyph stays the bar's own colour, which is what keeps
            // the label quiet on either appearance. The spec left this
            // underspecified — the mockup tinted the late-afternoon figure — and
            // this is the restrained reading of it.
            return Colours(fill: .pair(spectrum(progress)), glyphTint: nil,
                           track: emptyTrack, dashed: false)
        case .overtime:
            // Progress is ignored past target: the colour is discrete there, so a
            // ring that stopped short cannot come out a blended orange.
            return Colours(fill: .systemOrange, glyphTint: .systemOrange,
                           track: emptyTrack, dashed: false)
        case .atLimit:
            return Colours(fill: .systemRed, glyphTint: .systemRed,
                           track: emptyTrack, dashed: false)
        case .settled:
            return Colours(fill: .pair(neutral), glyphTint: nil, track: emptyTrack, dashed: false)
        }
    }

    /// Linear interpolation across `stops`.
    ///
    /// Total: `dayProgress` already guarantees `0...1`, but `resolve` is public
    /// surface and an unclamped or non-finite value would index out of bounds — and
    /// `Int(_: Double)` traps outright on `NaN`.
    ///
    /// The guard is `isNaN`, not `isFinite`, deliberately: the clamp below handles
    /// the infinities correctly on its own (`min(1, max(0, .infinity))` is 1), so
    /// only `NaN` — which fails every comparison and so survives a clamp — needs
    /// intercepting.
    static func spectrum(_ progress: Double) -> ColourPair {
        guard !progress.isNaN else { return stops[0] }
        let p = min(1, max(0, progress))
        let scaled = p * Double(stops.count - 1)
        // Clamped to the second-to-last stop so p == 1 lands on `t == 1` of the
        // final segment rather than reading one past the end.
        let i = min(stops.count - 2, Int(scaled.rounded(.down)))
        let t = scaled - Double(i)
        return ColourPair(light: lerp(stops[i].light, stops[i + 1].light, t),
                          dark: lerp(stops[i].dark, stops[i + 1].dark, t))
    }

    static func lerp(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(red: a.red + (b.red - a.red) * t,
             green: a.green + (b.green - a.green) * t,
             blue: a.blue + (b.blue - a.blue) * t,
             alpha: a.alpha + (b.alpha - a.alpha) * t)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LabelAppearanceTests`
Expected: PASS, all fourteen tests. If `testSpectrumClampsAndSurvivesNonFiniteInput` fails on `.infinity` by returning the _first_ stop, the guard was written as `isFinite` instead of `isNaN` — `±infinity` must fall through to the clamp.

- [ ] **Step 5: Confirm `KaltoeCore` still builds for Linux**

Run: `./scripts/build-linux.sh`
Expected: success. This is the guard on the "no SwiftUI in `KaltoeCore`" constraint. If the script is unavailable in this environment, instead verify by inspection that `LabelAppearance.swift` imports only `Foundation`, and say so in the commit.

- [ ] **Step 6: Commit**

```bash
git add Sources/KaltoeCore/LabelAppearance.swift Tests/KaltoeCoreTests/LabelAppearanceTests.swift
git commit -m "feat: LabelPhase and LabelPalette — the day-long colour spectrum"
```

---

### Task 5: `SettingsStore.labelGeometry`

Additive. The old setting is removed in Task 7, once nothing reads it.

**Files:**

- Modify: `Sources/KaltoeCore/SettingsStore.swift` (after `rules`, `:28`)
- Test: `Tests/KaltoeCoreTests/SettingsStoreTests.swift` (append)

**Interfaces:**

- Consumes: `LabelGeometry` from Task 4.
- Produces: `SettingsStore.labelGeometry: LabelGeometry`, get/set, defaulting to `.ring`. Tasks 6 and 7 use it.

- [ ] **Step 1: Write the failing tests**

Append inside `final class SettingsStoreTests`:

```swift
    func testLabelGeometryDefaultsToRing() {
        XCTAssertEqual(SettingsStore.labelGeometry, .ring)
    }

    func testLabelGeometryRoundTrips() {
        SettingsStore.labelGeometry = .track
        XCTAssertEqual(SettingsStore.labelGeometry, .track)
        XCTAssertEqual(SettingsStore.defaults.string(forKey: "labelGeometry"), "track")
        SettingsStore.labelGeometry = .ring
        XCTAssertEqual(SettingsStore.labelGeometry, .ring)
    }

    /// A hand-written `defaults write` can put anything here. An unrecognised value
    /// reads as the default rather than trapping or blanking the label.
    func testLabelGeometryFallsBackToRingForGarbage() {
        SettingsStore.defaults.set("spiral", forKey: "labelGeometry")
        XCTAssertEqual(SettingsStore.labelGeometry, .ring)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter SettingsStoreTests`
Expected: compile failure — `type 'SettingsStore' has no member 'labelGeometry'`.

- [ ] **Step 3: Implement it**

In `Sources/KaltoeCore/SettingsStore.swift`, after the `rules` property (`:28`):

```swift
    /// Menu bar label geometry. An absent or unrecognised value reads as `.ring`,
    /// so a typo in the documented `defaults write` degrades to the default rather
    /// than leaving the label undrawable.
    public static var labelGeometry: LabelGeometry {
        get { LabelGeometry(rawValue: defaults.string(forKey: "labelGeometry") ?? "") ?? .ring }
        set { defaults.set(newValue.rawValue, forKey: "labelGeometry") }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SettingsStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/SettingsStore.swift Tests/KaltoeCoreTests/SettingsStoreTests.swift
git commit -m "feat: persist the menu bar label geometry, defaulting to ring"
```

---

### Task 6: Rewrite `MenuBarLabel` — one render path, Ring and Track

The breaking swap. `MenuLabelStyle` and its tests go; the label's signature changes.

**Files:**

- Rewrite: `Sources/FlexTimer/MenuBarLabel.swift`
- Delete: `Sources/KaltoeCore/MenuLabelStyle.swift`, `Tests/KaltoeCoreTests/MenuLabelStyleTests.swift`
- Modify: `Sources/FlexTimer/AppState.swift` (`:8`, `:26-28` area, `recompute` at `:119-135`)
- Modify: `Sources/FlexTimer/FlexTimerApp.swift` (`:19-20`)

**Interfaces:**

- Consumes: `dayProgress` (Task 1), `labelGlyph`/`labelText` (Task 3), `LabelPhase`/`LabelPalette`/`LabelGeometry`/`ColourPair` (Task 4), `SettingsStore.labelGeometry` (Task 5).
- Produces: `AppState.labelProgress: Double`, `AppState.labelGeometry: LabelGeometry`; `MenuBarLabel(display:text:progress:geometry:)`. Task 7 binds `labelGeometry`.

There is no unit test here — `ImageRenderer` output is not assertable. The gate is that it builds, the suite stays green, and Task 8's hardware checklist is filled in. Verification is by running the app.

- [ ] **Step 1: Delete the superseded style enum and its tests**

```bash
git rm Sources/KaltoeCore/MenuLabelStyle.swift Tests/KaltoeCoreTests/MenuLabelStyleTests.swift
```

Run: `swift build 2>&1 | grep -E "error:"`
Expected: errors in `MenuBarLabel.swift` only — it is the sole consumer.

- [ ] **Step 2: Publish progress and geometry from `AppState`**

In `Sources/FlexTimer/AppState.swift`, add beside the other published properties (after `menuDisplay`, `:9`):

```swift
    /// Progress from clock-in to leave time, 0…1. Derived once per tick like
    /// `weekSummary`, so the label does no arithmetic in its body.
    @Published var labelProgress: Double = 0
    /// Mirrors the stored setting, written through on set so the picker persists,
    /// and published so the label re-renders the moment it changes.
    @Published var labelGeometry = SettingsStore.labelGeometry {
        didSet { SettingsStore.labelGeometry = labelGeometry }
    }
```

Leave `highContrastOnInactiveDisplays` in place — Task 7 removes it.

In `recompute` (`:119-135`), change the `menuText` assignment (`:131`) and add progress. The `record` local already exists at `:120`:

```swift
        menuDisplay = display
        menuText = display.state.labelText
        labelProgress = record.map {
            // Measured at clock-out once the day is closed, not at `now`. `dayProgress`
            // divides elapsed-since-clock-in by the whole span, so a settled day would
            // keep climbing all evening and read as a full ring hours after you went
            // home — when the whole point of the settled state is that a day ended short
            // of target visibly did not finish.
            WorkCalculator.dayProgress(clockIn: $0.clockIn, now: $0.clockOut ?? now,
                                       rules: rules,
                                       timeOff: WorkCalculator.timeOff(on: $0.clockIn,
                                                                       in: timeOff))
        } ?? 0
```

Leave the `menuText` initial value at `:8` alone: `.notClockedIn`'s `labelText` is still `--:--`, so the pre-first-tick label already matches the new vocabulary.

- [ ] **Step 3: Rewrite `MenuBarLabel.swift`**

Replace the file's entire contents:

```swift
import AppKit
import SwiftUI
import KaltoeCore

/// Menu bar label: a pre-rendered non-template `NSImage` in every state, drawn as
/// either a progress Ring around the glyph or a filling Track capsule behind the
/// whole label.
///
/// Non-template is the entire mechanism, and it is now unconditional. macOS greys
/// out template images on the menu bar of a display that does not hold the active
/// window, and also ignores colours on plain label views — rasterising sidesteps
/// both. That is why there is no longer a high-contrast preference: its benefit
/// applies always.
struct MenuBarLabel: View {
    let display: MenuDisplay
    let text: String
    /// 0…1, from `WorkCalculator.dayProgress`. Already clamped and finite.
    let progress: Double
    let geometry: LabelGeometry

    /// Resolves against the menu bar's own appearance, so every colour opposes
    /// whatever the bar is drawn in.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: rendered())
            .accessibilityLabel(spoken)
    }

    private var colours: LabelPalette.Colours {
        LabelPalette.resolve(progress: progress, phase: LabelPhase(display))
    }

    /// `.noSession` draws the glyph alone with no text, so VoiceOver would
    /// otherwise reach a nameless image.
    private var spoken: String {
        text.isEmpty ? "Signed out" : text
    }

    /// Resolves a fill. The `.system` cases are the whole reason `LabelFill` exists:
    /// they return the very colours the popover already draws, so the label's
    /// over-target orange **is** the week strip's orange rather than a tuned
    /// near-neighbour. `KaltoeCore` cannot name a SwiftUI colour, so it names the
    /// intent and this resolves it.
    private func colour(_ fill: LabelFill) -> Color {
        switch fill {
        case .pair(let pair): return colour(pair)
        case .systemOrange: return .orange
        case .systemRed: return .red
        }
    }

    private func colour(_ pair: ColourPair) -> Color {
        let c = colorScheme == .dark ? pair.dark : pair.light
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    private var barForeground: Color { colorScheme == .dark ? .white : .black }

    private var glyphColour: Color {
        // Not `map(colour)` — `colour` is overloaded, so the closure is ambiguous.
        guard let tint = colours.glyphTint else { return barForeground }
        return colour(tint)
    }

    // MARK: geometry

    private let ringSize: CGFloat = 14
    private let ringStroke: CGFloat = 2

    private var ring: some View {
        ZStack {
            Circle()
                .inset(by: ringStroke / 2)
                .stroke(colour(colours.track),
                        style: StrokeStyle(lineWidth: ringStroke, lineCap: .round,
                                           dash: colours.dashed ? [1.5, 2.0] : []))
            if !colours.dashed {
                Circle()
                    .inset(by: ringStroke / 2)
                    .trim(from: 0, to: progress)
                    .stroke(colour(colours.fill),
                            style: StrokeStyle(lineWidth: ringStroke, lineCap: .round))
                    // Start the arc at twelve o'clock rather than three.
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: display.state.labelGlyph)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(glyphColour)
        }
        .frame(width: ringSize, height: ringSize)
    }

    private var ringLabel: some View {
        HStack(spacing: 4) {
            ring
            if !text.isEmpty { Text(text).foregroundStyle(barForeground) }
        }
        .font(labelFont)
    }

    private var trackLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: display.state.labelGlyph).foregroundStyle(glyphColour)
            if !text.isEmpty { Text(text).foregroundStyle(barForeground) }
        }
        .font(labelFont)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(colour(colours.track))
                    if colours.dashed {
                        Capsule().strokeBorder(colour(colours.fill),
                                               style: StrokeStyle(lineWidth: 1, dash: [2.0, 2]))
                    } else {
                        // A Rectangle clipped to the capsule, not a narrowed Capsule:
                        // a short capsule reads as its own pill rather than as a fill.
                        Rectangle().fill(colour(colours.fill))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .clipShape(Capsule())
            }
        }
    }

    /// One font for every state, so type no longer changes size or weight as the
    /// label moves between them, and tabular digits so the width does not reflow
    /// as the countdown ticks.
    private var labelFont: Font {
        Font(NSFont.menuBarFont(ofSize: 0)).monospacedDigit()
    }

    @MainActor private func rendered() -> NSImage {
        let content = Group {
            switch geometry {
            case .ring: ringLabel
            case .track: trackLabel
            }
        }
        let renderer = ImageRenderer(content: content)
        // Render at the highest scale factor across all screens, not
        // NSScreen.main (the screen with the active window — precisely the
        // display this feature is not about). MenuBarExtra draws one image on
        // every menu bar, so rasterizing at the active display's scale would
        // upscale a 1x bitmap onto a 2x bar on mixed-DPI setups, blurring the
        // countdown on the very screen we're trying to keep legible.
        // Downsampling a high-res rep onto a 1x bar is fine; the reverse isn't.
        renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
```

- [ ] **Step 4: Update the call site**

In `Sources/FlexTimer/FlexTimerApp.swift`, replace the label closure body (`:19-20`):

```swift
            MenuBarLabel(display: state.menuDisplay, text: state.menuText,
                         progress: state.labelProgress, geometry: state.labelGeometry)
```

- [ ] **Step 5: Build and run the suite**

Run: `swift build`
Expected: clean.

Run: `swift test`
Expected: PASS. `MenuLabelStyleTests` is gone; every other test still green. If `AppStateTests` asserts on `menuText` containing `OT ` or `BREAK `, update those expectations to the prefix-free `labelText` values — that is the intended change, not a regression.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: rewrite the menu bar label as a ring or a filling track

One pre-rendered non-template image in every state, replacing the
plain/solid/pill branch. Retires MenuLabelStyle: with nothing template
any more, there is no dimming left for it to decide about."
```

---

### Task 7: The picker, and retiring the high-contrast setting

**Files:**

- Create: `Sources/FlexTimer/LabelGeometryRow.swift`
- Modify: `Sources/FlexTimer/MenuBarView.swift` (`:55`, and delete `highContrastRow` at `:157-177`)
- Modify: `Sources/FlexTimer/AppState.swift` (delete `:23-28`)
- Modify: `Sources/KaltoeCore/SettingsStore.swift` (delete `:30-36`)
- Modify: `Tests/KaltoeCoreTests/SettingsStoreTests.swift` (delete `:60-70`)

**Interfaces:**

- Consumes: `AppState.labelGeometry` (Task 6), `LabelGeometry` (Task 4).
- Produces: `LabelGeometryRow(geometry: Binding<LabelGeometry>)`.

- [ ] **Step 1: Create the picker row**

`Sources/FlexTimer/LabelGeometryRow.swift`:

```swift
import SwiftUI
import KaltoeCore

/// Menu bar label geometry picker.
///
/// A segmented `Picker` rather than a `MenuRow` toggle, because Ring and Track are
/// peer choices: a toggle would have to nominate one of them as the "on" state and
/// name itself after it.
struct LabelGeometryRow: View {
    @Binding var geometry: LabelGeometry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Label style").foregroundStyle(.secondary)
            Picker("Label style", selection: $geometry) {
                Text("Ring").tag(LabelGeometry.ring)
                Text("Track").tag(LabelGeometry.track)
            }
            .pickerStyle(.segmented)
            // The visible heading above already names the control; without this
            // the Picker draws its own title and says it twice.
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .help("Ring draws a closing arc around the icon; Track fills a capsule behind the whole label. Both stay legible on the menu bar of a display that doesn't have focus.")
        .accessibilityLabel("Menu bar label style")
    }
}
```

- [ ] **Step 2: Swap it into the popover**

In `Sources/FlexTimer/MenuBarView.swift`, replace `highContrastRow` at `:55`:

```swift
            LabelGeometryRow(geometry: $state.labelGeometry)
```

Delete the `highContrastRow` computed property entirely (`:157-177`).

- [ ] **Step 3: Remove the retired setting**

In `Sources/FlexTimer/AppState.swift`, delete the `highContrastOnInactiveDisplays` property and its doc comment (`:23-28`).

In `Sources/KaltoeCore/SettingsStore.swift`, delete the `highContrastOnInactiveDisplays` property and its doc comment (`:30-36`).

In `Tests/KaltoeCoreTests/SettingsStoreTests.swift`, delete `testHighContrastDefaultsToOff` and `testHighContrastRoundTrips` (`:60-70`).

The stale `UserDefaults` key needs no migration — it simply stops being read.

- [ ] **Step 4: Build and run the suite**

Run: `swift build && swift test`
Expected: clean build, all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: pick the label geometry in the popover, and retire high contrast

The setting existed only to stop macOS dimming a template label on an
unfocused display. Both geometries are non-template in every state, so
its benefit is now unconditional and the row has nothing to offer."
```

---

### Task 8: Documentation and the hardware checklist

The visual claims cannot be asserted in a test, so they get a durable checklist instead — the pattern set by `docs/superpowers/2026-07-30-week-strip-verification.md`.

**Files:**

- Modify: `README.md` (`:7-23` the phase list and pill paragraph; `:104` the high-contrast `defaults write`)
- Create: `docs/superpowers/2026-07-30-menu-bar-verification.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Replace the README's phase list**

Replace the bullet list at `README.md:9-16` — from `- **To lunch**:` through `- **Signed out**:` — with exactly this. Keep the surrounding `## What 칼퇴타이머 Shows` heading and its lead-in sentence, but change that sentence's "an icon plus text" to "a progress fill, a glyph and a countdown":

```markdown
- **To lunch**: `1:20` with a `fork.knife` icon — morning countdown to the lunch-leave moment (11:30 lunch start minus the 10-min early-leave allowance, i.e. counts down to 11:20)
- **On break**: `0:45` with a `cup.and.saucer` icon — during the 11:20–12:30 lunch window
- **Counting**: `2:34` with a `timer` icon — currently clocked in (outside the lunch window), showing time remaining until your leave time (clock-in + 8h work + 1h break)
- **Nearly 칼퇴**: `0:24` with a `figure.walk` icon — the last 30 minutes before leave time
- **자유!**: `자유!` with a `figure.walk.departure` icon — the first minute past your target. It occupies exactly the minute the overtime figure would render as `+0:00`, so it displaces nothing
- **Overtime**: `+1:00` with a `flame` icon — showing **today's** overtime: time worked beyond the 8h daily target. Overtime depends only on hours worked, never on when you work them — 09:00–19:00 and 07:00–17:00 are both 1h. The weekly total lives in the dropdown. On family day (last Friday of the month) the daily target is 6h, so the countdown targets leaving 2h early and doing so costs nothing.
  - Positive means you worked past today's target; negative means you clocked out short of it
  - Company limits: no more than 12h of overtime per week, and none past 22:00 — 칼퇴타이머 notifies you once when you cross either
- **Day settled**: `+1:00` with a `checkmark` icon — clocked out. The check means _settled_, not _target met_: a short day gets it too, beside a negative figure and a fill that visibly did not finish
- **Not clocked in**: `--:--` with a `timer` icon and an empty dashed fill — signed in but no active clock record
- **Signed out**: a `zzz` icon alone, with no number — no Flex session or logged out

The `BREAK` and `OT` word prefixes are gone from the menu bar label — the glyph carries the phase now. They remain on the **Linux tray**, which has no expressive glyph: on KDE that tray renders the countdown text alone, so `BREAK 0:45` is the only thing distinguishing a break from a countdown there.
```

- [ ] **Step 2: Replace the "Overwork warning colors" paragraph**

Replace `README.md:18-23` — the `**Overwork warning colors**:` paragraph, its two bullets and the "returns to the plain (non-pill) style" sentence — with exactly this:

```markdown
**Progress fill**: the label carries a fill showing how far the day has run from clock-in to leave time — a closing **ring** around the glyph, or a **track** capsule filling behind the whole label. Pick either in the dropdown under `Label style`. The fill measures distance to leaving rather than work completed, so it keeps advancing through the lunch break instead of stalling for an hour, and it never runs backwards when the countdown beside it switches from counting-to-lunch to counting-to-leave.

**Colour through the day**: the fill interpolates blue → teal → green → amber across the working day, so you can read roughly where you are without focusing on the digits. Past your target it goes flat **orange**, and **red** once you hit a company limit — 12h of overtime this week, or still clocked in past 22:00. The orange is the system orange the week strip already uses in the dropdown — literally the same colour, not a near match — so the label and the strip always agree about whether you are over. The red is the label's alone; the week strip has no limit colour, showing the weekly cap as text (`Week OT 5:00 / 12:00`) instead.

A day with no record shows an empty dashed fill. A day you have clocked out of shows a grey fill stopped at whatever it reached.

The label is drawn as a pre-rendered image in every state, so macOS never greys it out on the menu bar of a display that doesn't have focus. That used to be an opt-in setting; it is now unconditional.
```

- [ ] **Step 3: Remove the retired setting from the README**

Delete the `defaults write` block at `README.md:104` and the comment above it — the two lines beginning `# Keep the menu bar icon and time readable on the menu bar of an inactive` and the `defaults write com.perso.flextimer highContrastOnInactiveDisplays …` line that follows.

Do **not** add a `defaults write` line for `labelGeometry`. It is set from the popover, and Step 2 already documents it there.

Run: `grep -rn "highContrast" README.md`
Expected: no output.

- [ ] **Step 4: Create the verification checklist**

`docs/superpowers/2026-07-30-menu-bar-verification.md`, with unchecked boxes for each claim no test can reach:

```markdown
# Menu bar label — what only hardware can confirm

Spec: `specs/2026-07-30-menu-bar-overhaul-design.md`. Every item here is a claim
the unit tests cannot reach, because `ImageRenderer` output is not assertable.

## Both geometries

- [ ] Ring and Track are each legible at a glance on a dark menu bar.
- [ ] Both are legible on a **light** menu bar. Track is the risk: its text stays
      the bar's own colour and the fill opacity is capped rather than flipping the
      text to white, and the near-칼퇴 orange fill under dark text was the one
      mockup cell that looked wrong.
- [ ] Neither clashes with macOS 26's tinted / translucent menu bar over a busy
      wallpaper.
- [ ] Switching geometry in the popover re-renders the label immediately.
- [ ] Neither geometry is clipped or vertically off-centre in the 22pt bar.

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
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs/superpowers/2026-07-30-menu-bar-verification.md
git commit -m "docs: the new label's vocabulary, and one checklist for what hardware must confirm"
```

---

## Post-plan verification

Run the whole suite and the Linux build one final time:

```bash
swift test
./scripts/build-linux.sh
```

Then run the app and work through `docs/superpowers/2026-07-30-menu-bar-verification.md`. The light-appearance spectrum values are the most likely thing to need a follow-up commit.

Deferred by the spec, not forgotten: a `sunrise` morning sub-phase, a one-shot pulse animation on the overtime crossing, and Linux parity for the expressive glyph set.
