# Weekend State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace half-modelled weekend behaviour with one `주말!` state that short-circuits the weekday timer, and stop weekend work contributing overtime the UI cannot explain.

**Architecture:** One pure predicate (`isWeekend`) hoisted from an existing inline expression, one new `DisplayState` case checked early in `computeDisplay`, and one guard in `dailyOvertime` that covers the weekly total and the cap notifications because both are downstream of it. Three separately-approved fixes ride along: a non-finite guard in `Formatting`, memoisation of the label's rasterisation, and a parked docstring correction.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI + AppKit, XCTest, Python 3 (the Linux tray, comment only).

## Global Constraints

- **`KaltoeCore` must compile for Linux.** No SwiftUI or AppKit imports under `Sources/KaltoeCore/`.
- **The NDJSON wire gains a case but no existing state changes.** Every current `DisplayState`'s `menuBarText` and `iconName` output stays byte-identical. `Sources/KaltoeDaemon/` is not edited. `linux/kaltoe-tray.py` is edited **for a comment only** — no Python behaviour change.
- **Copy is exactly `주말!`** — Korean, with the exclamation mark, matching `자유!`.
- **The glyph is exactly `beach.umbrella`**, for both `labelGlyph` and `iconName`.
- `spokenLabel` for the new state is exactly `"Weekend"` — English, like its siblings.
- Test conventions: XCTest, `@testable import KaltoeCore`, the file-level `d(_ y:_ mo:_ da:_ h:_ mi:)` Asia/Seoul helper and `let rules = WorkRules()` from `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`.
- In `Double` array literals the leading element carries a decimal point — `[2.0, 2]`.
- Commit messages: lowercase conventional prefix.
- Reference spec: `docs/superpowers/specs/2026-07-31-weekend-state-design.md`.

**Reference dates** (verified against the Gregorian calendar): `2026-07-31` is a **Friday**, `2026-08-01` a **Saturday**, `2026-08-02` a **Sunday**, `2026-08-03` a **Monday**.

---

## File Structure

| File                                               | Responsibility                                   | Task |
| -------------------------------------------------- | ------------------------------------------------ | ---- |
| `Sources/KaltoeCore/WorkCalculator.swift`          | add `isWeekend`; guard `dailyOvertime`           | 1, 2 |
| `Sources/KaltoeCore/FlexRecordParser.swift`        | use `isWeekend` instead of the inline expression | 1    |
| `Sources/KaltoeCore/WeekSummary.swift`             | shrink the obsolete weekend comment              | 2    |
| `Sources/KaltoeCore/DisplayState.swift`            | `case weekend` + five mappings                   | 3    |
| `Sources/KaltoeCore/LabelAppearance.swift`         | `LabelPhase(.weekend) == .idle`                  | 3    |
| `Sources/KaltoeCore/Formatting.swift`              | non-finite guards on all three formatters        | 4    |
| `Sources/FlexTimer/MenuBarLabel.swift`             | memoise the rasterisation                        | 5    |
| `README.md`, `linux/kaltoe-tray.py`, the checklist | docs sweep                                       | 6    |

---

### Task 1: `isWeekend`, hoisted

**Files:**

- Modify: `Sources/KaltoeCore/WorkCalculator.swift` (add after `isFamilyDay`)
- Modify: `Sources/KaltoeCore/FlexRecordParser.swift:106`
- Test: `Tests/KaltoeCoreTests/WorkCalculatorTests.swift` (append)

**Interfaces:**

- Produces: `WorkCalculator.isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool`. Tasks 2 and 3 both call it.

- [ ] **Step 1: Write the failing test**

```swift
    // MARK: isWeekend

    /// Gregorian weekday numbering is 1 = Sunday … 7 = Saturday, so the weekday
    /// range is 2...6. Injected calendar, because the boundary is exactly where a
    /// host-timezone shift would move the answer.
    func testIsWeekendAcrossTheBoundary() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertFalse(WorkCalculator.isWeekend(d(2026, 7, 31, 12, 0), calendar: cal)) // Fri
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 1, 12, 0), calendar: cal))   // Sat
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 2, 12, 0), calendar: cal))   // Sun
        XCTAssertFalse(WorkCalculator.isWeekend(d(2026, 8, 3, 12, 0), calendar: cal))  // Mon
    }

    /// Midnight and one minute to midnight on the same Saturday, so a naive
    /// hour-of-day mistake cannot pass.
    func testIsWeekendHoldsAcrossTheWholeDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 1, 0, 0), calendar: cal))
        XCTAssertTrue(WorkCalculator.isWeekend(d(2026, 8, 1, 23, 59), calendar: cal))
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter WorkCalculatorTests`
Expected: compile failure — `type 'WorkCalculator' has no member 'isWeekend'`.

- [ ] **Step 3: Implement, and hoist the duplicate**

In `Sources/KaltoeCore/WorkCalculator.swift`, immediately after `isFamilyDay`:

```swift
    /// Saturday or Sunday.
    ///
    /// Not a new concept — `FlexRecordParser` already had to know weekday-ness to
    /// gate day-offs and time-off blocks, and computed it inline. This is that
    /// expression, named so both callers share one definition, and taking a
    /// `calendar` like the other date predicates here.
    public static func isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool {
        !(2...6).contains(calendar.component(.weekday, from: date))
    }
```

In `Sources/KaltoeCore/FlexRecordParser.swift:106`, replace:

```swift
            let isWeekday = dayDate.map { (2...6).contains(Calendar.current.component(.weekday, from: $0)) } ?? false
```

with:

```swift
            let isWeekday = dayDate.map { !WorkCalculator.isWeekend($0) } ?? false
```

The `?? false` stays: an unparseable date is treated as a non-weekday, which is the existing conservative behaviour.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS. The `FlexRecordParser` change is behaviour-identical, so its existing tests are the regression guard on the hoist.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/WorkCalculator.swift Sources/KaltoeCore/FlexRecordParser.swift Tests/KaltoeCoreTests/WorkCalculatorTests.swift
git commit -m "refactor: name the weekday predicate both callers were computing"
```

---

### Task 2: weekends earn no overtime

This task **inverts an existing test**. `testWeekendRecordCountsInTheTotalButHasNoRow` currently asserts the behaviour being removed, and the comment block it is named by describes a problem that ceases to exist.

**Files:**

- Modify: `Sources/KaltoeCore/WorkCalculator.swift` (`dailyOvertime`)
- Modify: `Sources/KaltoeCore/WeekSummary.swift:107-119` (shrink the comment)
- Test: `Tests/KaltoeCoreTests/WeekSummaryTests.swift:243-257` (invert), `Tests/KaltoeCoreTests/WorkCalculatorTests.swift` (append)

**Interfaces:**

- Consumes: `WorkCalculator.isWeekend` from Task 1.
- Produces: no new API. `dailyOvertime` returns 0 for a weekend record, so `weeklyOvertime`, `hasReachedWeeklyCap` and `WeekSummary.overtime` all follow.

- [ ] **Step 1: Invert the existing test**

Replace `Tests/KaltoeCoreTests/WeekSummaryTests.swift:243-257` entirely:

```swift
    /// Was `testWeekendRecordCountsInTheTotalButHasNoRow`, and asserted the opposite.
    /// A weekend record used to feed a total the Mon–Fri rows could not account for,
    /// so the rows summed to less than the figure printed beneath them. Weekends now
    /// earn nothing, which is what makes the rows and the total agree.
    func testWeekendRecordEarnsNoOvertimeAndHasNoRow() {
        let data = WeekData(records: [
            // Saturday 09:00–19:00: 10h gross, 9h net, which would have been +1:00.
            WorkRecord(clockIn: d(2026, 8, 1, 9, 0), clockOut: d(2026, 8, 1, 19, 0),
                       flexWorkedNet: nil)
        ])
        let s = WeekSummary.compute(from: data, now: d(2026, 8, 1, 19, 30), rules: rules)
        XCTAssertEqual(s.days.count, 5)
        XCTAssertTrue(s.days.allSatisfy { $0.worked == nil })
        XCTAssertEqual(s.days.reduce(0) { $0 + $1.overtime }, 0)
        // The rows and the total now agree, both at zero.
        XCTAssertEqual(s.overtime, 0)
        XCTAssertFalse(s.todayIsDayOff)
    }
```

- [ ] **Step 2: Write the calculator-level tests**

Append to `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`:

```swift
    /// A Saturday that would be +1:00 on a Tuesday earns nothing.
    func testDailyOvertimeIsZeroForAWeekendRecord() {
        let sat = WorkRecord(clockIn: d(2026, 8, 1, 9, 0), clockOut: d(2026, 8, 1, 19, 0),
                             flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: sat, now: d(2026, 8, 1, 20, 0),
                                                    rules: rules), 0)
        // The same shift on the Monday still earns it, so the guard is the weekend
        // and not the arithmetic.
        let mon = WorkRecord(clockIn: d(2026, 8, 3, 9, 0), clockOut: d(2026, 8, 3, 19, 0),
                             flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: mon, now: d(2026, 8, 3, 20, 0),
                                                    rules: rules), 3600)
    }

    /// An open weekend record earns nothing either — the live-accrual branch is a
    /// separate path through `dailyOvertime`.
    func testDailyOvertimeIsZeroForAnOpenWeekendRecord() {
        let sat = WorkRecord(clockIn: d(2026, 8, 1, 9, 0), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: sat, now: d(2026, 8, 1, 21, 0),
                                                    rules: rules), 0)
    }

    func testWeeklyOvertimeExcludesTheWeekend() {
        let records = [
            WorkRecord(clockIn: d(2026, 8, 1, 9, 0), clockOut: d(2026, 8, 1, 19, 0),
                       flexWorkedNet: nil),   // Sat, would be +1:00
            WorkRecord(clockIn: d(2026, 8, 3, 9, 0), clockOut: d(2026, 8, 3, 18, 0),
                       flexWorkedNet: nil),   // Mon, exactly on target
        ]
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: records,
                                                     now: d(2026, 8, 3, 20, 0),
                                                     rules: rules), 0)
    }
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter "WorkCalculatorTests|WeekSummaryTests"`
Expected: the three new calculator tests FAIL on the assertion (`0` expected, `3600` actual for the Saturday), and the inverted summary test FAILS asserting `s.overtime == 0`. These are assertion failures, not compile errors — the API already exists.

- [ ] **Step 4: Implement the guard**

In `Sources/KaltoeCore/WorkCalculator.swift`, as the first line of `dailyOvertime`'s body:

```swift
        // Weekends earn nothing. Not a tuning decision: the label refuses to show a
        // countdown on a weekend, so overtime it declines to explain must not reach
        // the weekly total or the cap notifications either — that divergence between
        // the strip's rows and the figure beneath them is the whole reason this
        // exists. Free by construction, too: `weeklyOvertime` floors each day at
        // zero, so a weekend day under target already contributed nothing.
        //
        // Resolves against `.current`, because `dailyOvertime` takes no calendar —
        // the same half-injected-calendar gap `WeekSummary.compute` documents and
        // follow-up 36 exists to close. Consequence to know: a test that injects a
        // calendar into `computeDisplay` gets weekend-awareness on the *state* and
        // `.current` on the *overtime*. Both agree on any KST machine.
        guard !isWeekend(record.clockIn) else { return 0 }
```

Placed before `timeOff`/`target` are computed, so both branches — completed and open — are covered by one guard.

- [ ] **Step 5: Shrink the obsolete comment**

In `Sources/KaltoeCore/WeekSummary.swift`, replace the comment at `:107-119` (from `// Five rows, Mon–Fri, always` through the `// testWeekendRecordCountsInTheTotalButHasNoRow.` line) with:

```swift
        // Five rows, Mon–Fri, always — weekends are deliberately not modelled, and
        // since `dailyOvertime` now returns 0 for a weekend record, the rows and the
        // total below them agree. Pinned by
        // `testWeekendRecordEarnsNoOvertimeAndHasNoRow`.
```

Thirteen lines become four. The paragraph they replace existed to explain a divergence that no longer happens.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS. Watch for any _other_ test that assumed weekend overtime — if one fails, read it before changing it, and say so in the commit.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: weekends earn no overtime, so the rows and the total agree

The strip is Mon-Fri, so a 9h Saturday used to add +1:00 to a total no row
could account for. Free by the premise nobody works 8h+ on a weekend day:
weeklyOvertime floors each day at zero, so a sub-target weekend day already
contributed nothing.

Inverts testWeekendRecordCountsInTheTotalButHasNoRow, which pinned exactly
the behaviour being removed, and deletes the paragraph in WeekSummary that
existed to explain the divergence."
```

---

### Task 3: `DisplayState.weekend`

**Files:**

- Modify: `Sources/KaltoeCore/DisplayState.swift`
- Modify: `Sources/KaltoeCore/LabelAppearance.swift` (`LabelPhase.init`)
- Test: `Tests/KaltoeCoreTests/FormattingTests.swift` (append to the phase suite), `Tests/KaltoeCoreTests/LabelVocabularyTests.swift`, `Tests/KaltoeCoreTests/LabelAppearanceTests.swift`, `Tests/KaltoeCoreTests/StatusLineTests.swift`

**Interfaces:**

- Consumes: `WorkCalculator.isWeekend` from Task 1.
- Produces: `DisplayState.weekend` (no associated values). Its `menuBarText` is `주말!`, `iconName` and `labelGlyph` are `beach.umbrella`, `labelText` is `주말!`, `spokenLabel` is `"Weekend"`, and `LabelPhase(.weekend)` is `.idle`.

`MenuBarLabel.fillFraction` needs **no** change: it switches on `LabelPhase`, not on `DisplayState`, and `.weekend` maps to the existing `.idle`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KaltoeCoreTests/LabelVocabularyTests.swift`:

```swift
    func testWeekendVocabulary() {
        XCTAssertEqual(DisplayState.weekend.labelGlyph, "beach.umbrella")
        XCTAssertEqual(DisplayState.weekend.labelText, "주말!")
        XCTAssertEqual(MenuDisplay(state: .weekend, urgency: .normal).spokenLabel, "Weekend")
    }
```

Append to `Tests/KaltoeCoreTests/LabelAppearanceTests.swift`:

```swift
    /// Weekend reuses the idle styling — neutral, dashed, no fill. There is nothing
    /// running, which is what `.idle` already means.
    func testWeekendIsIdlePhase() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .weekend, urgency: .normal)), .idle)
    }
```

Append to `Tests/KaltoeCoreTests/FormattingTests.swift`, inside `PhaseDisplayTests`:

```swift
    /// Saturday and Sunday short-circuit the whole weekday machine.
    func testWeekendBeatsAnyRecord() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let sat = WorkRecord(clockIn: d(2026, 8, 1, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: sat,
                                                  weeklyOvertime: 0,
                                                  now: d(2026, 8, 1, 14, 0), rules: rules,
                                                  calendar: cal)
        XCTAssertEqual(display.state, .weekend)
        XCTAssertEqual(display.urgency, .normal)
    }

    /// Signed out outranks it: "sign in" is actionable where 주말! is not.
    func testSignedOutBeatsWeekend() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let display = DisplayState.computeDisplay(hasSession: false, today: nil,
                                                  weeklyOvertime: 0,
                                                  now: d(2026, 8, 1, 14, 0), rules: rules,
                                                  calendar: cal)
        XCTAssertEqual(display.state, .noSession)
    }

    /// The Monday after is an ordinary day, so the guard is the weekday and not the
    /// presence of a record.
    func testWeekdayIsUnaffected() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let mon = WorkRecord(clockIn: d(2026, 8, 3, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: mon,
                                                  weeklyOvertime: 0,
                                                  now: d(2026, 8, 3, 14, 0), rules: rules,
                                                  calendar: cal)
        XCTAssertNotEqual(display.state, .weekend)
    }
```

Add one row to the wire-guard table in `Tests/KaltoeCoreTests/StatusLineTests.swift` (the `cases` array in `testWireTextAndIconAreUnchangedForEveryState`):

```swift
            (.weekend, "주말!", "beach.umbrella"),
```

Rename that test to `testWireTextAndIconForEveryState` in the same edit — "unchanged" is now false for one row, since `.weekend` is new rather than frozen. Update its doc comment's first sentence to say the table pins every state's wire output, and that the six pre-existing rows are frozen while `.weekend` is additive.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test 2>&1 | grep -E "error:" | head`
Expected: `type 'DisplayState' has no member 'weekend'`, plus — once the case is added in Step 3 — a **wave of non-exhaustive-switch errors**. That wave is the point: it enumerates the rest of this task.

- [ ] **Step 3: Add the case and let the compiler drive**

In `Sources/KaltoeCore/DisplayState.swift`, add to the enum after `notClockedIn`:

```swift
    case weekend                           // Saturday or Sunday — the timer stands down
```

In `computeDisplay`, immediately after the `hasSession` guard and **before** `guard let today`:

```swift
        // Weekends short-circuit everything below, a live record included: a countdown
        // to a notional leave time is noise on a Saturday. Signed-out stays above this
        // because "sign in" is something you can act on and 주말! is not. Urgency is
        // always `.normal` — there is nothing here to warn about.
        if WorkCalculator.isWeekend(now, calendar: calendar) {
            return MenuDisplay(state: .weekend, urgency: .normal)
        }
```

Then work the compiler's list. The five mappings, each a new `case`:

```swift
// menuBarText
        case .weekend: return "주말!"

// iconName — its own case, not folded into the `timer` list
        case .weekend: return "beach.umbrella"

// labelGlyph
        case .weekend: return "beach.umbrella"

// labelText
        case .weekend: return "주말!"

// spokenLabel
        case .weekend: return "Weekend"
```

In `Sources/KaltoeCore/LabelAppearance.swift`, in `LabelPhase.init`:

```swift
        case .weekend:
            // Nothing is running, which is exactly what `.idle` already draws:
            // neutral, dashed, no fill. No new palette branch needed.
            self = .idle
```

- [ ] **Step 4: Run the full suite**

Run: `swift build && swift test`
Expected: clean build, all tests PASS.

`swift build` does **not** compile test targets, so run `swift build --build-tests` or the full `swift test` before believing the switch wave is exhausted — a non-exhaustive switch in `Tests/` stays invisible to a plain build. If any switch still errors, it is a mapping this plan missed: add the `.weekend` case following the pattern above and note it in the commit.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: 주말! — the timer stands down at the weekend

One case checked between the session guard and the record lookup, so it
beats a live Saturday record without a weekend variant of every phase.
Signed-out still outranks it, because that one is actionable.

The wire gains a case rather than changing one: no existing state's
menuBarText or iconName moves, and beach.umbrella falls back to the generic
timer icon on Linux through ICON_BASE's .get."
```

---

### Task 4: `Formatting` stops trapping on non-finite input

Follow-up 28, approved separately. **The follow-up named `hm`; all three formatters have the same defect** — `Int(Double)` traps on NaN and on infinities, and every one of them evaluates it before any clamping.

**Files:**

- Modify: `Sources/KaltoeCore/Formatting.swift`
- Test: `Tests/KaltoeCoreTests/FormattingTests.swift` (append to `FormattingTests`)

**Interfaces:** no signature changes. All three functions become total.

- [ ] **Step 1: Write the failing tests**

```swift
    /// `Int(Double)` traps on NaN and on the infinities, and all three formatters
    /// reach it before clamping. This is not theoretical: `weeklyOvertimeCapHours`
    /// is a documented `defaults write` knob, and `MenuBarView` passes the cap
    /// straight into `hm`, so `-float nan` crash-looped the popover on input the
    /// daemon already survived.
    func testFormattersSurviveNonFiniteInput() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(Formatting.hm(bad), "0:00", "hm(\(bad))")
            XCTAssertEqual(Formatting.hms(bad), "0:00:00", "hms(\(bad))")
            XCTAssertEqual(Formatting.signedHM(bad), "+0:00", "signedHM(\(bad))")
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter FormattingTests`
Expected: a **crash**, not an assertion failure — the process traps inside `Int(_:)`. That is the defect. Note in the report that the RED here kills the test runner.

- [ ] **Step 3: Add the guards**

In `Sources/KaltoeCore/Formatting.swift`, one guard per function, each as the first line:

```swift
    /// "2:34" — floors to whole minutes, clamps negatives to "0:00".
    ///
    /// Total: `Int(Double)` traps on non-finite input and is evaluated before the
    /// clamp, and `rules.weeklyOvertimeCap` reaches here from a raw `Double` in
    /// `UserDefaults` that the README documents a `defaults write` for. `StatusLine`
    /// was hardened against exactly this; the popover was not.
    public static func hm(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00" }
        let m = max(0, Int(interval)) / 60
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "-2:59" / "+0:12" — explicit sign, zero shown as "+0:00".
    /// Non-finite yields "+0:00", matching how zero renders.
    public static func signedHM(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "+0:00" }
        let m = Int(abs(interval)) / 60
        let sign = (interval < 0 && m > 0) ? "-" : "+"
        return sign + "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "2:34:12". Non-finite yields "0:00:00", matching the negative clamp.
    public static func hms(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00:00" }
        let s = max(0, Int(interval))
        return "\(s / 3600):" + String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS, including the new test, and no crash.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/Formatting.swift Tests/KaltoeCoreTests/FormattingTests.swift
git commit -m "fix: the formatters trapped on non-finite input

Int(Double) traps on NaN and the infinities, and all three formatters
evaluated it before clamping. weeklyOvertimeCapHours is a documented
defaults write knob and MenuBarView passes the cap straight into hm, so
-float nan crash-looped the popover on input StatusLine already survived.

Follow-up 28 named hm; signedHM and hms had it too."
```

---

### Task 5: memoise the label's rasterisation

Measured 3% idle CPU. `body` runs about once a second because `display` carries a `timeLeft` that changes every tick, but the pixels almost never do — the text is minute-resolution and the fill advances a fraction of a pixel per second.

**Files:**

- Modify: `Sources/FlexTimer/MenuBarLabel.swift`

**Interfaces:** none — private to the view. No test: `ImageRenderer` output is not assertable and no SwiftUI view in this repo has tests. The gate is a clean build, a green suite, and a re-measurement of idle CPU.

- [ ] **Step 1: Quantise the fill, and key the palette off it**

Add beside the ring metrics:

```swift
    /// The fill advances in discrete steps, so the memoised render has something
    /// stable to key on. The ring's circumference is about 50pt, so at 2× one step
    /// is half a pixel — invisible — while a 9h day drops from 32,400 rasterisations
    /// to at most 200.
    private static let fillSteps: Double = 200
```

Change `fillFraction` to quantise on the way out, and `colours` to resolve from the quantised value so the two cannot disagree:

```swift
    private var colours: LabelPalette.Colours {
        LabelPalette.resolve(progress: fillFraction, phase: phase)
    }
```

```swift
    private var fillFraction: Double {
        let raw: Double
        switch phase {
        case .overtime, .atLimit: raw = 1
        case .idle, .working, .settled: raw = min(1, max(0, progress))
        }
        return (raw * Self.fillSteps).rounded() / Self.fillSteps
    }
```

Resolving the palette from `fillFraction` rather than `progress` is behaviour-identical: `resolve` reads `progress` only in the `.working` case, where `fillFraction` _is_ the clamped progress.

- [ ] **Step 2: Add the cache**

At file scope, below `MenuBarLabel`:

```swift
/// The rasterised label, memoised on everything that determines its pixels.
///
/// Main-actor isolated rather than `nonisolated(unsafe)`: `rendered()` is already
/// `@MainActor`, and there is exactly one menu bar label in the process, so a single
/// slot is the whole cache.
@MainActor private enum LabelRenderCache {
    struct Key: Equatable {
        let glyph: String
        let text: String
        let fill: Double
        let colours: LabelPalette.Colours
        let geometry: LabelGeometry
        let dark: Bool
        let scale: CGFloat
    }

    static var key: Key?
    static var image: NSImage?
}
```

- [ ] **Step 3: Consult it in `rendered()`**

Replace the opening of `rendered()` so the scale is computed once and folded into the key, and keep the existing mixed-DPI comment attached to that computation:

```swift
    @MainActor private func rendered() -> NSImage {
        // Render at the highest scale factor across all screens, not
        // NSScreen.main (the screen with the active window — precisely the
        // display this feature is not about). MenuBarExtra draws one image on
        // every menu bar, so rasterizing at the active display's scale would
        // upscale a 1x bitmap onto a 2x bar on mixed-DPI setups, blurring the
        // countdown on the very screen we're trying to keep legible.
        // Downsampling a high-res rep onto a 1x bar is fine; the reverse isn't.
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let key = LabelRenderCache.Key(glyph: display.state.labelGlyph, text: text,
                                       fill: fillFraction, colours: colours,
                                       geometry: geometry,
                                       dark: colorScheme == .dark, scale: scale)
        if key == LabelRenderCache.key, let cached = LabelRenderCache.image {
            return cached
        }

        let content = Group {
            switch geometry {
            case .ring: ringLabel
            case .track: trackLabel
            }
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        LabelRenderCache.key = key
        LabelRenderCache.image = image
        return image
    }
```

The key covers every input the render reads: glyph, text, fill fraction, resolved colours, geometry, appearance, and scale. `scale` is in it so plugging in a display re-renders.

- [ ] **Step 4: Build, test, and rebuild the bundle**

Run: `swift build && swift test && ./scripts/bundle.sh`
Expected: clean build, 206-plus tests passing, bundle signed with `kaltoe-dev`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/MenuBarLabel.swift
git commit -m "perf: memoise the label's raster on what actually determines it

body runs about once a second because display carries a timeLeft that
changes every tick, but the pixels almost never do: the text is
minute-resolution and the fill advances a fraction of a pixel per second.
Measured 3% idle CPU for one or two distinct images a minute.

The fill now advances in 200 discrete steps — half a pixel at 2x, so
invisible — which gives the cache a stable key and drops a 9h day from
32,400 rasterisations to at most 200."
```

---

### Task 6: the documentation sweep

**Files:**

- Modify: `README.md` (delete the weekend paragraph, add the weekend state to the phase list)
- Modify: `linux/kaltoe-tray.py` (comment only)
- Modify: `docs/superpowers/2026-07-30-menu-bar-verification.md` (two new checks)
- Modify: the project-memory follow-ups file (close 23, 33, 28, 37)

**Interfaces:** none.

Markdown edits go through `Bash` (a formatter hook reflows `.md` on `Edit`/`Write` and reindents unrelated lines). Verify with `git diff` that only intended lines moved.

- [ ] **Step 1: Delete the README's obsolete weekend paragraph**

Delete this paragraph in full — it documents a divergence Task 2 removed, so leaving it would make the README describe behaviour that no longer exists:

> **Monday–Friday only — weekend work is deliberately not in the strip**. A Saturday or Sunday record still counts toward `Week OT` but gets no row, so nine hours worked on a Saturday adds `+1:00` to the total with nothing on screen explaining it. That predates the strip (weekend days get the same 8h target as weekdays, which nobody chose); the strip only makes it noticeable. Recorded as follow-up 23, written up under "Weekends, and what this deliberately leaves alone" in `docs/superpowers/specs/2026-07-30-popover-week-graph-design.md`.

Find it by its opening bold run rather than by line number — the file has shifted. Afterwards, `grep -n "Monday–Friday only" README.md` must return nothing.

- [ ] **Step 2: Add the weekend state to the README's phase list**

After the `- **Signed out**:` bullet:

```markdown
- **Weekend**: `주말!` with a `beach.umbrella` icon — Saturday and Sunday. The timer stands down: no countdown, no target, and weekend hours earn no overtime, so the week strip's rows and the `Week OT` total always agree. A weekend clock-in is still recorded by Flex and still runs your clock hooks; 칼퇴타이머 just declines to count it.
```

- [ ] **Step 3: Fix the parked docstring in the Linux tray**

Follow-up 37. `linux/kaltoe-tray.py:84-85` claims the alert badge is "the only place the urgency colours appear on Linux at all, since a plain tray label carries no colour". False: the default `label` path appends `-warning`/`-critical` to the icon name (`:323-324`) and loads SVGs stroked `#ff9500`/`#ff3b30` — the same two colours as `PILL_COLORS`. Replace that clause with the narrower true statement:

> …the only place the urgency colours reach the **label text**; on the icon path they arrive as the `-warning`/`-critical` icon variants instead.

**No Python behaviour change.** Verify with `python3 -m py_compile linux/kaltoe-tray.py` and confirm `git diff linux/` shows only comment lines.

- [ ] **Step 4: Add the two hardware checks**

Append to the "Both geometries" section of `docs/superpowers/2026-07-30-menu-bar-verification.md`:

```markdown
- [ ] `beach.umbrella` is legible at 9pt inside the ring. It is a detailed glyph and
      may mush at that size; `sun.max` is the cleaner fallback, at the cost of
      meaning "sunny" rather than "weekend". Only observable on a Saturday or Sunday.
- [ ] The KDE text-icon path renders `주말!` rather than tofu boxes. Pango should
      resolve it, but the tray has never rendered Korean before.
```

- [ ] **Step 5: Close the resolved follow-ups**

In the project-memory follow-ups file, mark items **23**, **33**, **28** and **37** resolved, each with the commit that did it, in the style the file already uses for resolved items (strikethrough plus a `**RESOLVED**` note). Do not delete them — the file's convention is that resolved items stay visible with their reasoning.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: the weekend state, and four follow-ups closed

Deletes the README paragraph explaining a rows-versus-total divergence that
no longer happens, and corrects the tray docstring that claimed the alert
badge was the only place urgency colours appear on Linux — the label path
carries them as -warning/-critical icon variants."
```

---

## Post-plan verification

```bash
swift test
./scripts/build-linux.sh
./scripts/bundle.sh
```

Then relaunch and re-measure idle CPU with the popover closed — that number is the only evidence Task 5 worked. The two weekend hardware checks are observable tomorrow, 2026-08-01.
