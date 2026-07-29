# Overtime Weekly Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5h/week required-overtime mandate with a 12h/week cap and a 22:00 cutoff, show today's overtime in the menu bar instead of the week's, and notify once when either limit is crossed.

**Architecture:** The mandate lives entirely in `WorkCalculator.requiredOvertime`; deleting it removes the feature. `weeklyOvertime` becomes a gross sum (each day floored at zero) and feeds two new pure predicates that drive urgency. A `LimitNotifier` in `Sources/FlexTimer`, modelled on the existing `SessionNotifier`, posts one notification per period with dedupe keys persisted in `UserDefaults`.

**Tech Stack:** Swift 5.9, SwiftUI (`MenuBarExtra`), AppKit, UserNotifications, XCTest, SwiftPM.

Spec: `docs/superpowers/specs/2026-07-29-overtime-cap-design.md`

## Correction to the spec

The spec places `LimitNotifier` in `KaltoeCore`. That is wrong: the real
notification path needs `import UserNotifications`, which is macOS-only, and
`KaltoeCore` also builds for Linux. The existing `SessionNotifier` solves the
identical problem by living in `Sources/FlexTimer` with an injected `post`
closure and a `live()` factory guarded on being inside a real `.app` bundle.
This plan follows that established pattern instead. Everything else in the spec
stands.

## Global Constraints

- Swift tools version 5.9; deployment target macOS 13. No new dependencies.
- `KaltoeCore` must not import AppKit, SwiftUI, or UserNotifications — it also
  builds for Linux. All notification code stays in `Sources/FlexTimer`.
- **Overtime is time worked beyond the daily target, measured from clock-in, not
  from the wall clock.** 09:00–19:00 and 07:00–17:00 are both exactly 1h of
  overtime. Only the 22:00 cutoff is a wall-clock rule.
- **The weekly figure is gross:** `Σ max(0, dailyOvertime)`. A day worked short
  of target contributes zero and must never offset a long day.
- `dailyOvertime` stays **signed** — it still returns a negative value for a
  short day. Only the weekly aggregation floors at zero.
- Exact default values: `weeklyOvertimeCap = 12 * 3600`, `overtimeCutoff = 22 * 3600`
  (seconds from midnight, matching the `lunchStart`/`lunchEnd` convention).
- Exact new UserDefaults keys: `weeklyOvertimeCapHours`, `overtimeCutoffMinutes`.
  Exact removed keys: `weeklyOvertimeHours`, `dayOffDeductionHours`,
  `familyDayDeductionHours`. Domain: `com.perso.flextimer`.
- `familyDayEarlyLeave` and `familyDayEarlyLeaveHours` are **not** part of this
  change. They govern the daily target, not overtime. Leave them alone.
- `dayOffDates` parsing in `FlexClient`, its threading through `WeekData` and
  `AppState`, and its `FlexClientTests` coverage are **deliberately retained**.
  Only the deduction that consumed it is removed.
- **Markdown files must be edited via Bash, never Edit or Write.** A global
  prettier `PostToolUse` hook reflows markdown on write and has already
  corrupted unrelated lines in this README once. After any markdown edit, run
  `git diff -- <file>` and confirm only intended lines changed.
- Run tests from the repo root with `swift test`. Build the app bundle with
  `./scripts/bundle.sh`.

## File Structure

| File                                       | Responsibility                                             | Task |
| ------------------------------------------ | ---------------------------------------------------------- | ---- |
| `Sources/KaltoeCore/WorkCalculator.swift`  | Rules model; overtime arithmetic; the two limit predicates | 1, 2 |
| `Sources/KaltoeCore/SettingsStore.swift`   | UserDefaults → `WorkRules`                                 | 1, 2 |
| `Sources/KaltoeCore/DisplayState.swift`    | What the menu bar shows and how urgent it is               | 3    |
| `Sources/FlexTimer/LimitNotifier.swift`    | One notification per crossing, per period (new)            | 4    |
| `Sources/FlexTimer/AppState.swift`         | Wiring: call sites and notifier attachment                 | 2, 4 |
| `Sources/FlexTimer/MenuBarView.swift`      | Popover Week OT row                                        | 2, 5 |
| `Sources/KaltoeDaemon/HeadlessState.swift` | Linux status line call sites                               | 2    |
| `README.md`, `linux/README-linux.md`       | User-facing documentation                                  | 5    |

---

### Task 1: The two limits

Purely additive — nothing is removed yet, so the package compiles and all
existing tests keep passing throughout.

**Files:**

- Modify: `Sources/KaltoeCore/WorkCalculator.swift` (add 2 fields to `WorkRules`; add 2 functions)
- Modify: `Sources/KaltoeCore/SettingsStore.swift` (2 lines in `rules`)
- Test: `Tests/KaltoeCoreTests/WorkCalculatorTests.swift` (append)
- Test: `Tests/KaltoeCoreTests/SettingsStoreTests.swift` (append)

**Interfaces:**

- Consumes: `WorkRules` (`Sources/KaltoeCore/WorkCalculator.swift:3-16`), `SettingsStore.defaults`.
- Produces:
  - `WorkRules.weeklyOvertimeCap: TimeInterval` (default `12 * 3600`)
  - `WorkRules.overtimeCutoff: TimeInterval` (default `22 * 3600`)
  - `WorkCalculator.isPastOvertimeCutoff(now:rules:calendar:) -> Bool`
  - `WorkCalculator.hasReachedWeeklyCap(weeklyOvertime:rules:) -> Bool`

  Tasks 3 and 4 both call the two predicates.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`, inside the existing
test class. Note the explicit Seoul calendar: `isPastOvertimeCutoff` compares
against midnight, so a test that relied on the machine's `Calendar.current`
would be non-deterministic.

```swift
    private var seoul: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    func testIsPastOvertimeCutoffAtBoundary() {
        let rules = WorkRules()  // 22:00
        XCTAssertFalse(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 21, 59), rules: rules, calendar: seoul))
        XCTAssertTrue(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 22, 0), rules: rules, calendar: seoul))
        XCTAssertTrue(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 23, 30), rules: rules, calendar: seoul))
    }

    func testIsPastOvertimeCutoffRespectsCustomCutoff() {
        var rules = WorkRules()
        rules.overtimeCutoff = 20 * 3600  // 20:00
        XCTAssertFalse(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 19, 59), rules: rules, calendar: seoul))
        XCTAssertTrue(WorkCalculator.isPastOvertimeCutoff(
            now: d(2026, 7, 29, 20, 0), rules: rules, calendar: seoul))
    }

    func testHasReachedWeeklyCapAtBoundary() {
        let rules = WorkRules()  // 12h
        XCTAssertFalse(WorkCalculator.hasReachedWeeklyCap(
            weeklyOvertime: 11 * 3600 + 3599, rules: rules))
        XCTAssertTrue(WorkCalculator.hasReachedWeeklyCap(
            weeklyOvertime: 12 * 3600, rules: rules))
        XCTAssertTrue(WorkCalculator.hasReachedWeeklyCap(
            weeklyOvertime: 20 * 3600, rules: rules))
    }
```

Append to `Tests/KaltoeCoreTests/SettingsStoreTests.swift`, inside the existing
class:

```swift
    func testDefaultOvertimeLimits() {
        let r = SettingsStore.rules
        XCTAssertEqual(r.weeklyOvertimeCap, 12 * 3600)
        XCTAssertEqual(r.overtimeCutoff, 22 * 3600)
    }

    func testOverriddenOvertimeLimits() {
        SettingsStore.defaults.set(10.0, forKey: "weeklyOvertimeCapHours")
        SettingsStore.defaults.set(1260.0, forKey: "overtimeCutoffMinutes")  // 21:00
        let r = SettingsStore.rules
        XCTAssertEqual(r.weeklyOvertimeCap, 10 * 3600)
        XCTAssertEqual(r.overtimeCutoff, 1260 * 60)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorkCalculatorTests`
Expected: FAIL — compile error, `type 'WorkCalculator' has no member 'isPastOvertimeCutoff'` and `value of type 'WorkRules' has no member 'weeklyOvertimeCap'`.

- [ ] **Step 3: Add the rules fields**

In `Sources/KaltoeCore/WorkCalculator.swift`, add to `WorkRules` immediately
after the `weeklyOvertime` line (which is still present at this point and will
be removed in Task 2):

```swift
    public var weeklyOvertimeCap: TimeInterval = 12 * 3600  // max overtime allowed per week
    public var overtimeCutoff: TimeInterval = 22 * 3600     // no overtime past this, seconds from midnight
```

- [ ] **Step 4: Add the two predicates**

In `Sources/KaltoeCore/WorkCalculator.swift`, add after `dailyTarget` (which
ends around line 96):

```swift
    /// True once `now` is at or past the day's overtime cutoff. This is the
    /// only wall-clock rule in the model — overtime itself is measured from
    /// clock-in, so a 07:00 start and a 09:00 start accrue identically.
    public static func isPastOvertimeCutoff(now: Date, rules: WorkRules,
                                            calendar: Calendar = .current) -> Bool {
        now.timeIntervalSince(calendar.startOfDay(for: now)) >= rules.overtimeCutoff
    }

    /// True once the week's overtime has reached the allowed ceiling.
    public static func hasReachedWeeklyCap(weeklyOvertime: TimeInterval,
                                           rules: WorkRules) -> Bool {
        weeklyOvertime >= rules.weeklyOvertimeCap
    }
```

- [ ] **Step 5: Read the new settings keys**

In `Sources/KaltoeCore/SettingsStore.swift`, add inside the `rules` computed
property, after the `lunchEarlyLeaveMinutes` line:

```swift
        if let h = defaults.object(forKey: "weeklyOvertimeCapHours") as? Double { r.weeklyOvertimeCap = h * 3600 }
        if let m = defaults.object(forKey: "overtimeCutoffMinutes") as? Double { r.overtimeCutoff = m * 60 }
```

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS — all pre-existing tests plus the 5 new ones. Nothing was
removed, so no existing test should change behaviour.

- [ ] **Step 7: Commit**

```bash
git add Sources/KaltoeCore/WorkCalculator.swift Sources/KaltoeCore/SettingsStore.swift \
        Tests/KaltoeCoreTests/WorkCalculatorTests.swift Tests/KaltoeCoreTests/SettingsStoreTests.swift
git commit -m "feat: weekly overtime cap and nightly cutoff rules"
```

---

### Task 2: Delete the mandate

The largest task, and necessarily atomic: removing `WorkRules.weeklyOvertime`
breaks `requiredOvertime`, which breaks `weeklyOvertime`, which breaks its three
call sites. The compiler will not let these be separated.

**Files:**

- Modify: `Sources/KaltoeCore/WorkCalculator.swift` (remove 3 `WorkRules` fields; delete `requiredOvertime`; rewrite `weeklyOvertime`)
- Modify: `Sources/KaltoeCore/DisplayState.swift` (drop the `dayOffs` parameter from `computeDisplay`)
- Modify: `Sources/KaltoeCore/SettingsStore.swift` (remove 3 lines)
- Modify: `Sources/FlexTimer/AppState.swift:74-78` (call site)
- Modify: `Sources/FlexTimer/MenuBarView.swift:43-45` (call site)
- Modify: `Sources/KaltoeDaemon/HeadlessState.swift:36-50` (two call sites)
- Test: `Tests/KaltoeCoreTests/WorkCalculatorTests.swift` (delete 12 tests, rewrite 4)
- Test: `Tests/KaltoeCoreTests/SettingsStoreTests.swift` (amend 3 tests)
- Test: `Tests/FlexTimerTests/AppStateTests.swift` (delete 1 test)

**Interfaces:**

- Consumes: nothing new from Task 1.
- Produces:
  - `WorkCalculator.weeklyOvertime(records:timeOff:now:rules:) -> TimeInterval` — note **no `dayOffs` parameter**. Gross sum.
  - `DisplayState.computeDisplay(hasSession:today:week:timeOff:now:rules:calendar:) -> MenuDisplay` — note **no `dayOffs` parameter**.

  Tasks 3, 4 and 5 all use these signatures.

- [ ] **Step 1: Write the failing test for gross summing**

This is the behaviour that did not exist before and is the point of the task.
Append to `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`:

```swift
    /// A short day has no hours *over* the target, so it contributes zero — it
    /// must not offset a long day. Under the old net-against-quota model these
    /// two days cancelled to 0; under the cap model the week is +1h.
    func testWeeklyOvertimeShortDayContributesZero() {
        let rules = WorkRules()
        let now = d(2026, 7, 31, 18, 0)
        // 09:00-19:00 = 10h elapsed - 1h lunch = 9h net = +1h overtime
        let long = WorkRecord(clockIn: d(2026, 7, 27, 9, 0),
                              clockOut: d(2026, 7, 27, 19, 0), flexWorkedNet: nil)
        // 09:00-17:00 = 8h elapsed - 1h lunch = 7h net = -1h, floored to 0
        let short = WorkRecord(clockIn: d(2026, 7, 28, 9, 0),
                               clockOut: d(2026, 7, 28, 17, 0), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [long, short],
                                                     now: now, rules: rules),
                       3600, accuracy: 1)
    }

    func testWeeklyOvertimeEmptyWeekIsZero() {
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [],
                                                     now: d(2026, 7, 31, 18, 0),
                                                     rules: WorkRules()),
                       0, accuracy: 1)
    }

    func testWeeklyOvertimeSumsTwoLongDays() {
        let rules = WorkRules()
        let now = d(2026, 7, 31, 18, 0)
        let a = WorkRecord(clockIn: d(2026, 7, 27, 9, 0),
                           clockOut: d(2026, 7, 27, 19, 0), flexWorkedNet: nil)   // +1h
        let b = WorkRecord(clockIn: d(2026, 7, 28, 9, 0),
                           clockOut: d(2026, 7, 28, 20, 30), flexWorkedNet: nil)  // +2h30
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [a, b],
                                                     now: now, rules: rules),
                       3600 + 9000, accuracy: 1)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter testWeeklyOvertimeShortDayContributesZero`
Expected: FAIL — either a compile error on the missing `dayOffs` argument label, or an assertion failure showing `0` (the old net behaviour) against the expected `3600`.

- [ ] **Step 3: Remove the mandate from `WorkRules`**

In `Sources/KaltoeCore/WorkCalculator.swift`, delete these three lines from
`WorkRules`:

```swift
    public var weeklyOvertime: TimeInterval = 5 * 3600  // required overtime per week
    public var dayOffDeduction: TimeInterval = 1 * 3600     // weekly-required reduction per holiday/vacation weekday
    public var familyDayDeduction: TimeInterval = 1 * 3600  // weekly-required reduction for a family-day week
```

Keep `familyDayEarlyLeave` — it governs the daily target, not overtime.

- [ ] **Step 4: Delete `requiredOvertime` and rewrite `weeklyOvertime`**

Delete the whole `requiredOvertime` function (its doc comment plus body, around
lines 98-122).

Replace `weeklyOvertime` (around lines 68-77) with:

```swift
    /// Overtime worked this week: the sum of each day's overtime, floored at
    /// zero per day. A day worked short of target contributes nothing rather
    /// than offsetting a long day — "hours over the target" cannot be negative.
    /// `timeOff` keys must be `Calendar.current.startOfDay`-normalized dates.
    public static func weeklyOvertime(records: [WorkRecord],
                                      timeOff: [Date: TimeInterval] = [:],
                                      now: Date, rules: WorkRules) -> TimeInterval {
        records.reduce(0) {
            $0 + max(0, dailyOvertime(record: $1, now: now, rules: rules, timeOff: timeOff))
        }
    }
```

- [ ] **Step 5: Drop `dayOffs` from `computeDisplay`**

In `Sources/KaltoeCore/DisplayState.swift`, remove the `dayOffs: Set<Date> = []`
parameter from `computeDisplay` and update its internal `weeklyOvertime` call to
drop the `dayOffs:` argument. `dayOffs` had no other use in that function.

- [ ] **Step 6: Fix the three call sites**

`Sources/FlexTimer/AppState.swift`, in `recompute` — remove the `dayOffs: dayOffDates,` line from the `computeDisplay` call.

`Sources/FlexTimer/MenuBarView.swift:43-45` — remove `dayOffs: state.dayOffDates,` from the `weeklyOvertime` call.

`Sources/KaltoeDaemon/HeadlessState.swift` — remove `dayOffs: weekData.dayOffDates,` from **both** the `computeDisplay` call (line 39) and the `weeklyOvertime` call (line 48).

Leave `AppState.dayOffDates`, `WeekData.dayOffDates`, and the `FlexClient`
parsing in place — they are deliberately retained per the spec.

- [ ] **Step 7: Remove the three settings keys**

In `Sources/KaltoeCore/SettingsStore.swift`, delete the lines reading
`weeklyOvertimeHours`, `dayOffDeductionHours`, and `familyDayDeductionHours`.
Keep the `familyDayEarlyLeaveHours` line.

- [ ] **Step 8: Delete the mandate's tests**

From `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`, delete these twelve test
functions entirely — they test behaviour that no longer exists:

```
testRequiredOvertimePlainWeek
testRequiredOvertimeDeductsPerDayOff
testRequiredOvertimeIgnoresDayOffsOutsideWeek
testRequiredOvertimeFamilyDayWeek
testFamilyDayVacationCoincidenceDeductsOnce
testRequiredOvertimeFloorsAtZero
testWeeklyOvertimeUsesAdjustedRequirement
testRequiredOvertimeDeductsFullHourPerTimeOffDay
testRequiredOvertimeMergesTimeOffAndHolidayDays
testRequiredOvertimeSameDayHolidayAndTimeOffDeductsOnce
testRequiredOvertimeHalfDayOnFamilyDayNoDoubleCount
testRequiredOvertimeIgnoresTimeOffOutsideWeek
```

Also delete the three superseded weekly tests, replaced by Step 1's versions:

```
testWeeklyOvertimeCanonical
testWeeklyOvertimeEmptyWeek
testWeeklyOvertimeMixedWeek
```

Keep `testWeeklyOvertimeThreadsTimeOffThroughDailySum` but update its call to
drop the `dayOffs:` argument; if its expected value assumed net offsetting,
recompute it for the gross sum.

Do **not** touch `testFamilyDayLeaveTimeIsTwoHoursEarlier`,
`testFamilyDayEarlyLeaveIsFree`, `testIsFamilyDayLastFridayOnly`,
`testFamilyDayOpenRecordAccruesAfterEarlyLeaveTime`, or any leave-time, lunch,
or time-off test.

- [ ] **Step 9: Amend the settings tests**

In `Tests/KaltoeCoreTests/SettingsStoreTests.swift`:

- `testOverriddenRules` — remove the `weeklyOvertimeHours` set and its assertion; keep the `dailyWorkHours` and `breakMinutes` halves.
- `testDefaultHolidayAndFamilyDayRules` — remove the `dayOffDeduction` and `familyDayDeduction` assertions; keep `familyDayEarlyLeave`.
- `testOverriddenHolidayAndFamilyDayRules` — same: keep only the `familyDayEarlyLeaveHours` case.

- [ ] **Step 10: Delete the obsolete AppState test**

From `Tests/FlexTimerTests/AppStateTests.swift`, delete
`testDayOffAdjustsWeeklyCounterInMenuText`. It asserts that a day off reduces
the weekly counter — the exact behaviour being removed.

Other tests in that file assert menu text like `"OT -1:58"` which came from the
net-against-quota model. Those are addressed in Task 3, when the menu bar
switches to today's figure; if they fail at this step, leave them failing and
note it — Task 3 fixes them.

- [ ] **Step 11: Run the full suite**

Run: `swift build && swift test`
Expected: the package compiles. `WorkCalculatorTests` and `SettingsStoreTests`
pass. Some `AppStateTests`/`FormattingTests` assertions on `.overtime` text may
still fail — that is expected and is Task 3's job. Record exactly which ones
fail in your report.

- [ ] **Step 12: Commit**

```bash
git add Sources/KaltoeCore/WorkCalculator.swift Sources/KaltoeCore/DisplayState.swift \
        Sources/KaltoeCore/SettingsStore.swift Sources/FlexTimer/AppState.swift \
        Sources/FlexTimer/MenuBarView.swift Sources/KaltoeDaemon/HeadlessState.swift \
        Tests/KaltoeCoreTests/WorkCalculatorTests.swift Tests/KaltoeCoreTests/SettingsStoreTests.swift \
        Tests/FlexTimerTests/AppStateTests.swift
git commit -m "feat!: remove the weekly overtime mandate, sum overtime gross"
```

---

### Task 3: Today's overtime, and urgency from the limits

**Files:**

- Modify: `Sources/KaltoeCore/DisplayState.swift` (the `.overtime` case, `menuBarText`, the tail of `computeDisplay`)
- Test: `Tests/KaltoeCoreTests/FormattingTests.swift` (rewrite 4 tests, add 4)
- Test: `Tests/FlexTimerTests/AppStateTests.swift` (fix any assertions left failing by Task 2)

**Interfaces:**

- Consumes: `WorkCalculator.hasReachedWeeklyCap(weeklyOvertime:rules:)` and `WorkCalculator.isPastOvertimeCutoff(now:rules:calendar:)` from Task 1; `weeklyOvertime(records:timeOff:now:rules:)` from Task 2.
- Produces: `DisplayState.overtime(today: TimeInterval)` — the associated value is now **today's** overtime, not the week's.

- [ ] **Step 1: Write the failing tests**

In `Tests/KaltoeCoreTests/FormattingTests.swift`, replace
`testOvertimeAfterLeaveTime` and `testOvertimeAfterClockingOutEarly` in
`DisplayStateTests`, and `testPastLeaveStillClockedInIsCritical` /
`testClockedOutOvertimeIsNormal` in `PhaseDisplayTests`, with the following.
Add a Seoul calendar to whichever class you place the urgency tests in, as in
Task 1.

```swift
    /// Still on the clock an hour past leave time: the menu bar shows today's
    /// overtime, not the week's, and overtime alone is only a warning.
    func testOvertimePastLeaveTimeShowsTodayAndWarns() {
        let rules = WorkRules()
        let today = WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  week: [today],
                                                  now: d(2026, 7, 29, 19, 0),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.state, .overtime(today: 3600))
        XCTAssertEqual(display.state.menuBarText, "OT +1:00")
        XCTAssertEqual(display.urgency, .warning)
    }

    /// Clocked out short of target: today's figure is negative and the day is
    /// settled, so nothing is urgent.
    func testOvertimeClockedOutEarlyShowsNegativeAndIsNormal() {
        let rules = WorkRules()
        let today = WorkRecord(clockIn: d(2026, 7, 29, 9, 0),
                               clockOut: d(2026, 7, 29, 17, 0), flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  week: [today],
                                                  now: d(2026, 7, 29, 17, 30),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.state, .overtime(today: -3600))
        XCTAssertEqual(display.state.menuBarText, "OT -1:00")
        XCTAssertEqual(display.urgency, .normal)
    }

    /// Past 22:00 while still clocked in: critical, and today's figure keeps
    /// accruing rather than freezing at the cutoff.
    func testPastCutoffWhileClockedInIsCritical() {
        let rules = WorkRules()
        let today = WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: nil, flexWorkedNet: nil)
        let display = DisplayState.computeDisplay(hasSession: true, today: today,
                                                  week: [today],
                                                  now: d(2026, 7, 29, 22, 30),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.urgency, .critical)
        XCTAssertEqual(display.state, .overtime(today: 4.5 * 3600))
    }

    /// The weekly cap is critical regardless of clock state — 12h worked is 12h
    /// worked whether or not you are currently on the clock.
    func testWeeklyCapIsCriticalEvenWhenClockedOut() {
        let rules = WorkRules()
        // Four completed 12h-elapsed days = 11h net each = +3h overtime each = 12h for the week.
        let week = (27...30).map { day in
            WorkRecord(clockIn: d(2026, 7, day, 8, 0),
                       clockOut: d(2026, 7, day, 20, 0), flexWorkedNet: nil)
        }
        let display = DisplayState.computeDisplay(hasSession: true, today: week.last!,
                                                  week: week,
                                                  now: d(2026, 7, 30, 20, 30),
                                                  rules: rules, calendar: seoul)
        XCTAssertEqual(display.urgency, .critical)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FormattingTests`
Expected: FAIL — compile error on `.overtime(today:)` (the case is still `.overtime(weekly:)`).

- [ ] **Step 3: Rename the case and its text**

In `Sources/KaltoeCore/DisplayState.swift`:

```swift
    case overtime(today: TimeInterval)   // overtime worked today; negative if short
```

and in `menuBarText`:

```swift
        case .overtime(let today): return "OT " + Formatting.signedHM(today)
```

- [ ] **Step 4: Compute today's figure and the new urgency**

Replace the tail of `computeDisplay` (currently lines 54-59, the `let weekly = …`
through the final `return`) with:

```swift
        // Weekly total is computed for the cap check only — the menu bar shows today.
        let weekly = WorkCalculator.weeklyOvertime(records: week, timeOff: timeOff,
                                                   now: now, rules: rules)
        let todayOvertime = WorkCalculator.dailyOvertime(record: today, now: now,
                                                         rules: rules, timeOff: timeOff)
        let clockedIn = today.clockOut == nil
        let urgency: Urgency
        if WorkCalculator.hasReachedWeeklyCap(weeklyOvertime: weekly, rules: rules) {
            urgency = .critical                     // cap applies on or off the clock
        } else if clockedIn, WorkCalculator.isPastOvertimeCutoff(now: now, rules: rules,
                                                                 calendar: calendar) {
            urgency = .critical                     // working past the cutoff
        } else if clockedIn {
            urgency = .warning                      // in overtime, within both limits
        } else {
            urgency = .normal                       // day settled
        }
        return MenuDisplay(state: .overtime(today: todayOvertime), urgency: urgency)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter FormattingTests`
Expected: PASS.

- [ ] **Step 6: Fix any remaining AppState assertions**

Run: `swift test`

`Tests/FlexTimerTests/AppStateTests.swift` has assertions on overtime menu text
(`testRecomputePicksTodayAndSetsMenuText` asserts `"OT -1:58"`;
`testWeekRolloverDropsLastWeeksRecordsFromSum` and
`testHalfDayDrivesReducedCountdownAndWeeklySum` also assert overtime values).
Recompute each expected value for the new model — today's overtime rather than
the week's net-against-quota — and update the assertions. Do not delete these
tests; they cover real `AppState` wiring.

- [ ] **Step 7: Run the full suite**

Run: `swift build && swift test`
Expected: PASS, output pristine.

- [ ] **Step 8: Commit**

```bash
git add Sources/KaltoeCore/DisplayState.swift Tests/KaltoeCoreTests/FormattingTests.swift \
        Tests/FlexTimerTests/AppStateTests.swift
git commit -m "feat: menu bar shows today's overtime, urgency tracks the limits"
```

---

### Task 4: LimitNotifier

**Files:**

- Create: `Sources/FlexTimer/LimitNotifier.swift`
- Create: `Tests/FlexTimerTests/LimitNotifierTests.swift`
- Modify: `Sources/FlexTimer/AppState.swift` (property, attach in `start()`, call in `recompute`)

**Interfaces:**

- Consumes: `WorkCalculator.hasReachedWeeklyCap`, `WorkCalculator.isPastOvertimeCutoff`, `WorkCalculator.weekStart(of:calendar:)`, `WorkCalculator.weeklyOvertime(records:timeOff:now:rules:)`.
- Produces: `LimitNotifier(defaults:calendar:post:)`, `evaluate(weeklyOvertime:clockedIn:now:rules:)`, `LimitNotifier.live()`.

Model this on `Sources/FlexTimer/SessionNotifier.swift` — same injected-poster
shape, same `.app`-bundle guard in the `live()` factory, tests in the same style
as `Tests/FlexTimerTests/SessionNotifierTests.swift`.

Dedupe uses **two fixed keys holding a date stamp**, not one boolean key per
period. A boolean-per-period scheme would accumulate a new `UserDefaults` key
every week and every day forever; storing the last-notified stamp under a fixed
key re-arms naturally when the stamp changes and never grows.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlexTimerTests/LimitNotifierTests.swift`:

```swift
import XCTest
@testable import FlexTimer
import KaltoeCore

/// Date in Asia/Seoul, gregorian. Duplicated per this repo's convention:
/// separate test targets don't share top-level helpers.
private func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
}

private let seoul: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return c
}()

final class LimitNotifierTests: XCTestCase {
    private var posted: [String] = []
    private var defaults: UserDefaults!
    private var notifier: LimitNotifier!
    private let rules = WorkRules()   // 12h cap, 22:00 cutoff

    override func setUp() {
        posted = []
        defaults = UserDefaults(suiteName: "limit-tests-\(UUID().uuidString)")!
        notifier = LimitNotifier(defaults: defaults, calendar: seoul) { [self] in posted.append($0) }
    }

    func testCapFiresOnceThenStaysSilent() {
        let now = d(2026, 7, 29, 18, 0)
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true, now: now, rules: rules)
        XCTAssertEqual(posted.count, 1)
        // recompute runs every second — the next ticks must be silent
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 18, 1), rules: rules)
        notifier.evaluate(weeklyOvertime: 13 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 19, 0), rules: rules)
        XCTAssertEqual(posted.count, 1)
    }

    func testCapDoesNotFireBelowTheCeiling() {
        notifier.evaluate(weeklyOvertime: 11 * 3600 + 3599, clockedIn: true,
                          now: d(2026, 7, 29, 18, 0), rules: rules)
        XCTAssertEqual(posted, [])
    }

    func testCapReArmsInANewWeek() {
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 18, 0), rules: rules)   // Wed
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 8, 5, 18, 0), rules: rules)    // next Wed
        XCTAssertEqual(posted.count, 2)
    }

    func testCutoffFiresOnceThenStaysSilent() {
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 29, 22, 0), rules: rules)
        XCTAssertEqual(posted.count, 1)
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 29, 22, 30), rules: rules)
        XCTAssertEqual(posted.count, 1)
    }

    func testCutoffStaysSilentWhenClockedOut() {
        notifier.evaluate(weeklyOvertime: 0, clockedIn: false,
                          now: d(2026, 7, 29, 23, 0), rules: rules)
        XCTAssertEqual(posted, [])
    }

    func testCutoffReArmsTheNextDay() {
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 29, 22, 30), rules: rules)
        notifier.evaluate(weeklyOvertime: 0, clockedIn: true,
                          now: d(2026, 7, 30, 22, 30), rules: rules)
        XCTAssertEqual(posted.count, 2)
    }

    /// Relaunching the app after a crossing must not re-notify: a fresh
    /// notifier over the same defaults sees the stored stamp.
    func testDoesNotReFireAfterRelaunch() {
        notifier.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                          now: d(2026, 7, 29, 22, 30), rules: rules)
        XCTAssertEqual(posted.count, 2)   // cap + cutoff both crossed
        let relaunched = LimitNotifier(defaults: defaults, calendar: seoul) { [self] in posted.append($0) }
        relaunched.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                            now: d(2026, 7, 29, 22, 31), rules: rules)
        XCTAssertEqual(posted.count, 2)
    }

    @MainActor
    func testLiveFactoryIsInertOutsideAppBundle() {
        // Under swift test the main bundle is not a .app, so live() must return
        // a notifier whose poster never touches UNUserNotificationCenter.
        let live = LimitNotifier.live()
        live.evaluate(weeklyOvertime: 12 * 3600, clockedIn: true,
                      now: d(2026, 7, 29, 22, 30), rules: rules)
        // Reaching here without a bundleProxy crash is the assertion.
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LimitNotifierTests`
Expected: FAIL — compile error, `cannot find 'LimitNotifier' in scope`.

- [ ] **Step 3: Write `LimitNotifier`**

Create `Sources/FlexTimer/LimitNotifier.swift`:

```swift
import Foundation
import UserNotifications
import KaltoeCore

/// Posts at most one macOS notification per period when a company overtime
/// limit is crossed: the weekly cap once per week, the nightly cutoff once per
/// day.
///
/// Dedupe is the substance of this type, not a detail. `AppState.recompute`
/// runs every second, so an undeduped notifier would fire thousands of times an
/// hour. Each limit stores the stamp of the period it last notified for under a
/// fixed key — so it re-arms when the period changes, never accumulates keys,
/// and survives relaunch (reopening the app at 22:30 must not re-notify).
///
/// The poster is injected so the logic is testable; the real poster comes from
/// `live()` and is only safe inside a real .app bundle (attach in
/// AppState.start(), like HookRunner and SessionNotifier).
final class LimitNotifier {
    private static let capKey = "limitNotifiedCapWeek"
    private static let cutoffKey = "limitNotifiedCutoffDay"

    private let post: (String) -> Void
    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults, calendar: Calendar = .current,
         post: @escaping (String) -> Void) {
        self.defaults = defaults
        self.calendar = calendar
        self.post = post
    }

    func evaluate(weeklyOvertime: TimeInterval, clockedIn: Bool, now: Date, rules: WorkRules) {
        if WorkCalculator.hasReachedWeeklyCap(weeklyOvertime: weeklyOvertime, rules: rules) {
            let week = WorkCalculator.weekStart(of: now, calendar: calendar)
            fireOnce(key: Self.capKey, stamp: stamp(week),
                     body: "Weekly overtime cap reached — stop for this week.")
        }
        if clockedIn, WorkCalculator.isPastOvertimeCutoff(now: now, rules: rules,
                                                          calendar: calendar) {
            fireOnce(key: Self.cutoffKey, stamp: stamp(now),
                     body: "Past the overtime cutoff — clock out and go home.")
        }
    }

    private func fireOnce(key: String, stamp: String, body: String) {
        guard defaults.string(forKey: key) != stamp else { return }
        defaults.set(stamp, forKey: key)
        post(body)
    }

    private func stamp(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Real UNUserNotificationCenter wiring. UNUserNotificationCenter.current()
    /// crashes outside a real .app bundle (swift test / swift run), hence the guard.
    @MainActor
    static func live() -> LimitNotifier {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return LimitNotifier(defaults: .standard, post: { _ in })
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        return LimitNotifier(defaults: .standard) { body in
            let content = UNMutableNotificationContent()
            content.title = "칼퇴타이머"
            content.body = body
            center.add(UNNotificationRequest(identifier: "overtime-limit-\(UUID().uuidString)",
                                             content: content, trigger: nil))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LimitNotifierTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Wire it into `AppState`**

In `Sources/FlexTimer/AppState.swift`, add alongside the existing `hookRunner`
and `sessionNotifier` properties:

```swift
    /// Attached in start() only, so unit tests calling recompute never notify.
    var limitNotifier: LimitNotifier?
```

In `start()`, next to `hookRunner = HookRunner()`:

```swift
        limitNotifier = LimitNotifier.live()
```

In `recompute(now:)`, after `menuText = display.state.menuBarText`:

```swift
        limitNotifier?.evaluate(
            weeklyOvertime: WorkCalculator.weeklyOvertime(records: weekIncludingManual(now: now),
                                                          timeOff: timeOff, now: now, rules: rules),
            clockedIn: record?.clockOut == nil && record != nil,
            now: now, rules: rules)
```

- [ ] **Step 6: Run the full suite**

Run: `swift build && swift test`
Expected: PASS, output pristine. Existing `AppStateTests` must still pass —
`limitNotifier` is nil unless `start()` ran, so `recompute` stays silent in tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlexTimer/LimitNotifier.swift Tests/FlexTimerTests/LimitNotifierTests.swift \
        Sources/FlexTimer/AppState.swift
git commit -m "feat: notify once when the weekly cap or nightly cutoff is crossed"
```

---

### Task 5: Popover context and documentation

**Files:**

- Modify: `Sources/FlexTimer/MenuBarView.swift:43-45`
- Modify: `README.md` (six regions)
- Modify: `linux/README-linux.md:48`

**Interfaces:**

- Consumes: `WorkCalculator.weeklyOvertime(records:timeOff:now:rules:)`, `WorkRules.weeklyOvertimeCap`, `Formatting.hm`.
- Produces: nothing downstream.

**Markdown warning:** edit `README.md` and `linux/README-linux.md` via Bash
only — a prettier `PostToolUse` hook reflows markdown written with Edit/Write
and has already corrupted unrelated lines in this README once. Verify each edit
with `git diff -- <file>`.

- [ ] **Step 1: Show the cap in the popover**

In `Sources/FlexTimer/MenuBarView.swift`, replace the Week OT row (lines 43-45)
with:

```swift
            let weekOT = WorkCalculator.weeklyOvertime(
                records: state.weekIncludingManual(now: Date()),
                timeOff: state.timeOff, now: Date(), rules: state.rules)
            row("Week OT", "\(Formatting.hm(weekOT)) / \(Formatting.hm(state.rules.weeklyOvertimeCap))")
```

`Formatting.hm` rather than `signedHM`: the weekly figure is a gross sum and can
no longer be negative.

- [ ] **Step 2: Build and run the suite**

Run: `swift build && swift test`
Expected: PASS.

- [ ] **Step 3: Update `README.md`**

Seven regions. Apply each with a Bash-driven `python3` edit — never Edit/Write.
The replacement text is given verbatim; match on the current text shown.

**3a. Line 3, top-level description** — no change. It says "overtime tracking",
which is still accurate. Listed here so you do not go looking for one.

**3b. The Overtime phase bullet and its four sub-bullets.** Replace:

```
- **Overtime**: `OT -2:59` with a `timer` icon — after leave time, showing the weekly overtime counter. It resets to -5:00 every Monday at 00:00 (the 5h weekly overtime target) and updates live once you're past your daily leave time. The requirement adjusts automatically: each holiday or vacation weekday reported by Flex deducts 1h, and a family-day week (last Friday of the month) deducts another 1h — e.g. a week with one public holiday plus family day requires 3h. On family day itself the daily target is 6h, so the countdown targets leaving 2h early and doing so costs nothing.
    - Negative means you're still short of this week's 5h overtime target
    - Positive means you've exceeded the weekly target
    - Working past your daily leave time moves the counter up; leaving early moves it down
    - Offline manual entries carry no holiday data, so fully-offline weeks show the unadjusted requirement
```

with:

```
- **Overtime**: `OT +1:00` with a `timer` icon — after leave time, showing **today's** overtime: time worked beyond the 8h daily target. Overtime depends only on hours worked, never on when you work them — 09:00–19:00 and 07:00–17:00 are both 1h. The weekly total lives in the dropdown. On family day (last Friday of the month) the daily target is 6h, so the countdown targets leaving 2h early and doing so costs nothing.
    - Positive means you worked past today's target; negative means you clocked out short of it
    - Company limits: no more than 12h of overtime per week, and none past 22:00 — 칼퇴타이머 notifies you once when you cross either
```

**3c. The "Overwork warning colors" bullets.** Task 3 changed these: overtime
alone is no longer red. Replace:

```
- **Orange pill** — ≤ 30 min before leave time
- **Red pill** — ≤ 10 min before leave time, or any time you're still clocked in past leave time
```

with:

```
- **Orange pill** — ≤ 30 min before leave time, or while accruing overtime within the company limits
- **Red pill** — ≤ 10 min before leave time, or once you hit a limit: 12h of overtime this week, or still clocked in past 22:00
```

**3d. The dropdown bullet.** Replace:

```
- Shows today's work record (start time, end time if clocked out, overtime balance for the week)
```

with:

```
- Shows today's work record (start time, end time if clocked out, and the week's overtime against the 12h cap)
```

**3e. The `weeklyOvertimeHours` settings entry.** Delete these two lines:

```
# Weekly overtime target in hours (default: 5.0)
defaults write com.perso.flextimer weeklyOvertimeHours -float 6.0
```

and add, in the same bash block:

```
# Maximum overtime allowed per week, in hours (default: 12.0)
defaults write com.perso.flextimer weeklyOvertimeCapHours -float 12.0

# No overtime past this time, in minutes from midnight (default: 1320 = 22:00)
defaults write com.perso.flextimer overtimeCutoffMinutes -float 1320
```

**3f. The deduction settings entries.** Delete the `dayOffDeductionHours` and
`familyDayDeductionHours` lines. **Keep the `familyDayEarlyLeaveHours` line** —
it governs the daily target and is not part of this change.

**3g. "Daily and Weekly Calculations".** Replace:

```
- **Daily overtime** = (clock-out time) − (leave time), or current elapsed − (leave time) if still clocked in
- **Weekly overtime** = sum of daily overtime for all worked days in the current week (Monday 00:00 reset)
```

with:

```
- **Daily overtime** = (clock-out time) − (leave time), or current elapsed − (leave time) if still clocked in; negative if you clocked out short of the target
- **Weekly overtime** = sum of daily overtime for all worked days in the current week, **each day floored at 0** (Monday 00:00 reset) — a short day contributes nothing and never offsets a long one
```

Leave the "Unworked days ... contribute 0" line that follows it unchanged.


- [ ] **Step 4: Verify the README diff is clean**

Run: `git diff -- README.md`
Expected: only the six regions above changed. If unrelated lines moved
(indentation, list reflow, line wrapping), the formatter hook ran — revert and
redo via Bash.

- [ ] **Step 5: Update `linux/README-linux.md`**

In the "What the tray shows" section, replace:

```
Same phases as the Mac app: countdown to lunch (fork icon), break (cup),
countdown to leave time (timer), and the weekly overtime counter (`OT -2:59`)
after leave time. The icon turns orange within 30 minutes of leave time and
red within 10 minutes or while overworking.
```

with:

```
Same phases as the Mac app: countdown to lunch (fork icon), break (cup),
countdown to leave time (timer), and today's overtime (`OT +1:00`) after leave
time. The week's total against the 12h cap is in the tray menu. The icon turns
orange within 30 minutes of leave time and while accruing overtime, and red
within 10 minutes of leave time or once you hit a company limit.
```

Apply via Bash, then run `git diff -- linux/README-linux.md` and confirm only
that paragraph changed.


- [ ] **Step 6: Build the bundle**

Run: `./scripts/bundle.sh`
Expected: succeeds. **Do not launch the app** — the user is running 칼퇴타이머
and a second instance from the build directory would register a Login Item
pointing at a build path. The human runs the visual check.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlexTimer/MenuBarView.swift README.md linux/README-linux.md
git commit -m "feat: show weekly overtime against the cap; document the new rules"
```

---

## Human verification

Not runnable by an agent — the user performs these after `./scripts/bundle.sh`:

1. Past leave time while clocked in: menu bar shows today's overtime in orange.
2. Popover Week OT reads `x:xx / 12:00`.
3. A short day earlier in the week does not reduce the weekly total.
4. Set `overtimeCutoffMinutes` a few minutes ahead, restart, stay clocked in:
   exactly one notification at the crossing and none on subsequent ticks.
