# Popover Week Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a per-day view of the week in the macOS popover and the Linux tray menu, plus a line explaining why today's target is shorter than eight hours.

**Architecture:** One new value type, `KaltoeCore.WeekSummary`, is computed once per tick from data already fetched, then consumed by three surfaces: the menu bar pill, the SwiftUI popover, and the daemon's NDJSON status line. The SwiftUI view and the daemon compute nothing themselves. Existing calculations are untouched — everything added is additive and display-only.

**Tech Stack:** Swift 6 language mode, swift-tools-version 6.0, macOS 26 floor, XCTest, SwiftUI (`MenuBarExtra(.window)`), Python 3 + GTK3/AppIndicator for the Linux tray.

**Spec:** `docs/superpowers/specs/2026-07-30-popover-week-graph-design.md`

## Global Constraints

- **Do not change** `leaveTime`, `timeLeft`, `dailyOvertime`, `weeklyOvertime`, `dailyTarget`, `breakDuration`, `DisplayState`, the menu bar pill, or the limit notifications. No existing test should need editing. If one breaks, that is a defect in the new code.
- **Weekdays only.** The week strip is always exactly 5 rows, Monday to Friday. Weekend records are deliberately excluded — see the spec's "Weekends" section. Do not add weekend awareness to `dailyTarget`.
- **The caption string is pinned** to `Target <hm> · <reasons>`, reasons drawn from `family day` and `time off`, comma-joined in that order, carrying no amount. Example: `Target 4:00 · family day, time off`. Composed once in `KaltoeCore` and shipped to Linux verbatim.
- **Every interval crossing the NDJSON boundary is integer seconds truncated to the whole minute.** The daemon emits on change (`Sources/KaltoeDaemon/main.swift:39`); a second-resolution field would turn a once-per-minute emission into once per second.
- **New public types need explicit `public init`s.** `FlexTimer` and `KaltoeDaemon` are separate modules, so a synthesised memberwise initialiser is internal and unreachable from them.
- **Warning gate:** `rm -rf .build && swift build --build-tests`, run once. A warm `swift build` re-emits nothing and does not compile test targets.
- Test dates use the existing helper convention: `d(y, mo, da, h, mi)` in Asia/Seoul, gregorian, duplicated per test target (targets do not share top-level helpers).

## The canonical test week

Every task below uses this one week, which matches the reviewed mockups. Monday of the week containing any of these dates is 2026-07-27.

| Day | Date | Clock | Net worked | Target | Overtime |
|---|---|---|---|---|---|
| Mon | 2026-07-27 | 09:00–18:35 | 8:35 | 8:00 | +0:35 |
| Tue | 2026-07-28 | 09:00–19:10 | 9:10 | 8:00 | +1:10 |
| Wed | 2026-07-29 | 09:00–17:40 | 7:40 | 8:00 | 0 (short days floor at zero) |
| Thu | 2026-07-30 | — | — | 8:00 | 0 (in `dayOffDates`) |
| Fri | 2026-07-31 | 09:12, still on the clock | 4:29 | 6:00 | 0 |

`now` = 2026-07-31 14:41. **Week OT = 1:45.**

2026-07-31 is the last Friday of July 2026 (adding 7 days lands in August), so it is a family day and its target is `8:00 − 2:00`. 2026-07-24 is a Friday that is *not* the last one — useful as a negative case.

---

## File Structure

**Create:**
- `Sources/KaltoeCore/WeekSummary.swift` — `DaySummary`, `WeekSummary`, `WeekSummary.compute`, `TargetNote.compose`. The whole per-day model in one focused file.
- `Sources/FlexTimer/WeekBarRow.swift` — the SwiftUI row that draws one day's bar. Separate from `MenuBarView` because it is the only drawing code in the app and `MenuBarView` is already the largest view file.
- `Tests/KaltoeCoreTests/WeekSummaryTests.swift`
- `linux/kaltoe_rows.py` — pure label formatting for the tray, importable without GTK.

**Modify:**
- `Sources/KaltoeCore/WorkCalculator.swift` — add `breakTaken`.
- `Sources/KaltoeCore/StatusLine.swift` — add `days`, `targetNote`, `weekOvertimeCap`, and the nested `DayLine`.
- `Sources/FlexTimer/AppState.swift:114-131` — publish the summary from `recompute`.
- `Sources/FlexTimer/MenuBarView.swift` — caption row, "Day off", the week strip; stop computing weekly overtime.
- `Sources/KaltoeDaemon/HeadlessState.swift:47-70` — build the summary and pass it to `StatusLine`.
- `linux/kaltoe-tray.py` — five day rows, the caption row, the cap denominator.
- `linux/install.sh:8` — copy the new Python module.
- `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`, `Tests/KaltoeDaemonTests/HeadlessStateTests.swift`, `Tests/FlexTimerTests/AppStateTests.swift`.

---

### Task 1: `breakTaken` — the lunch already consumed

Today's bar needs hours worked *so far*. The existing break subtraction deducts the full hour up front, which would pin the bar at zero until 10:12 on a 09:12 start. This function deducts only the part of lunch that has actually happened.

**Files:**
- Modify: `Sources/KaltoeCore/WorkCalculator.swift` (add after `breakDuration`, around `:43`)
- Test: `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`

**Interfaces:**
- Consumes: `WorkCalculator.dailyTarget`, `WorkCalculator.breakDuration`, `WorkRules.lunchStart`, `WorkRules.lunchEnd` (all existing).
- Produces: `WorkCalculator.breakTaken(clockIn:now:rules:timeOff:calendar:) -> TimeInterval`, used by Task 3.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KaltoeCoreTests/WorkCalculatorTests.swift`. The file already defines the `d(...)` helper and a top-level `let rules = WorkRules()`.

```swift
    // MARK: breakTaken

    func testBreakTakenIsZeroBeforeLunchStarts() {
        // Clocked in 09:12, now 10:00 — the 11:30 lunch has not begun.
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 10, 0), rules: rules), 0)
    }

    func testBreakTakenAccruesDuringLunch() {
        // Lunch runs 11:30–12:30. At 12:00, half of it is spent.
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 12, 0), rules: rules),
                       30 * 60)
    }

    func testBreakTakenCapsAtTheFullBreakAfterLunch() {
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 16, 0), rules: rules),
                       3600)
    }

    /// Clocking in after lunch never consumed it, so nothing is deducted — this is
    /// the case a naive `now − lunchStart` would get wrong.
    func testBreakTakenIsZeroWhenClockingInAfterLunch() {
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 13, 0),
                                                 now: d(2026, 7, 31, 18, 0), rules: rules), 0)
    }

    /// A half-day target has no break at all (breakDuration returns 0), so there is
    /// none to consume even long after the lunch window.
    func testBreakTakenIsZeroWhenTheDayHasNoBreak() {
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 29, 9, 0),
                                                 now: d(2026, 7, 29, 18, 0), rules: rules,
                                                 timeOff: 4 * 3600), 0)
    }

    /// The cap is the day's break, not the window's width: a 30-minute break inside
    /// a 60-minute window stops at 30.
    func testBreakTakenCapsAtTheBreakNotTheWindow() {
        var short = WorkRules()
        short.breakTime = 30 * 60
        XCTAssertEqual(WorkCalculator.breakTaken(clockIn: d(2026, 7, 31, 9, 12),
                                                 now: d(2026, 7, 31, 16, 0), rules: short),
                       30 * 60)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WorkCalculatorTests.testBreakTaken`
Expected: compile failure — `type 'WorkCalculator' has no member 'breakTaken'`.

- [ ] **Step 3: Implement**

Add to `Sources/KaltoeCore/WorkCalculator.swift`, directly after `breakDuration`:

```swift
    /// The break *already consumed* by `now`: the overlap of `[clockIn, now]` with
    /// the day's lunch window, capped at the day's break.
    ///
    /// Exists because the day's bar needs hours worked so far, and deducting the
    /// whole break up front would hold that at zero until an hour past clock-in.
    ///
    /// Uses `rules.lunchStart` rather than `lunchWindow(on:)`'s `leaveAt`, which is
    /// shifted earlier by `lunchEarlyLeave`. That shift serves the "you may leave
    /// for lunch now" countdown; break *accounting* has to follow the official
    /// window, or a worker who never leaves early would be debited time they
    /// worked.
    public static func breakTaken(clockIn: Date, now: Date, rules: WorkRules,
                                  timeOff: TimeInterval = 0,
                                  calendar: Calendar = .current) -> TimeInterval {
        let target = dailyTarget(on: clockIn, rules: rules, timeOff: timeOff, calendar: calendar)
        let cap = breakDuration(target: target, rules: rules)
        guard cap > 0 else { return 0 }
        let midnight = calendar.startOfDay(for: clockIn)
        let overlap = min(now, midnight.addingTimeInterval(rules.lunchEnd))
            .timeIntervalSince(max(clockIn, midnight.addingTimeInterval(rules.lunchStart)))
        return min(cap, max(0, overlap))
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WorkCalculatorTests`
Expected: PASS, including every pre-existing case in the class.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/WorkCalculator.swift Tests/KaltoeCoreTests/WorkCalculatorTests.swift
git commit -m "feat: breakTaken — the lunch consumed so far

Hours worked so far cannot deduct the whole break up front; that would hold
today's figure at zero until an hour past clock-in. Overlap with the official
lunch window, capped at the day's break."
```

---

### Task 2: `TargetNote.compose` — the caption string

**Files:**
- Create: `Sources/KaltoeCore/WeekSummary.swift`
- Test: `Tests/KaltoeCoreTests/WeekSummaryTests.swift`

**Interfaces:**
- Consumes: `WorkCalculator.timeOff(on:in:calendar:)`, `WorkCalculator.dailyTarget`, `WorkCalculator.isFamilyDay`, `Formatting.hm` (all existing).
- Produces: `TargetNote.compose(on:rules:timeOff:calendar:) -> String?`, used by Task 3 and consumed as `WeekSummary.targetNote`.

**Deviation from the spec, deliberate:** the spec names this
`targetReduction(on:rules:timeOff:)` returning the target *plus a list of
reasons*, with the string composed from it afterwards. Nothing needs the reasons
separately — the only consumer is the caption — so the intermediate tuple is
dropped and the string is composed in one step. If a caller ever needs the
reasons structurally, split it then.

- [ ] **Step 1: Write the failing tests**

Create `Tests/KaltoeCoreTests/WeekSummaryTests.swift`. `d(...)` and `rules` are already top-level in this target (`WorkCalculatorTests.swift`), so do not redeclare them.

```swift
import XCTest
@testable import KaltoeCore

final class TargetNoteTests: XCTestCase {
    /// An ordinary Wednesday: nothing shortened the day, so there is nothing to say.
    func testOrdinaryDayHasNoNote() {
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 29, 9, 0), rules: rules, timeOff: [:]))
    }

    /// 2026-07-31 is the last Friday of July, so the family-day reduction applies.
    func testFamilyDayAlone() {
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: rules, timeOff: [:]),
                       "Target 6:00 · family day")
    }

    func testTimeOffAlone() {
        let key = Calendar.current.startOfDay(for: d(2026, 7, 29, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 29, 9, 0), rules: rules,
                                          timeOff: [key: 2 * 3600]),
                       "Target 6:00 · time off")
    }

    /// The compounding case, and the reason this feature exists: both reductions
    /// land on one day, and the break vanishes too, so Leave at moves five hours:
    /// 8h + 1h break becomes 4h + no break, not 4h + 1h.
    func testFamilyDayAndTimeOffStack() {
        let key = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: rules,
                                          timeOff: [key: 2 * 3600]),
                       "Target 4:00 · family day, time off")
    }

    /// A Friday that is not the last one in its month is an ordinary day.
    func testNonFinalFridayIsNotAFamilyDay() {
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 24, 9, 0), rules: rules, timeOff: [:]))
    }

    /// familyDayEarlyLeave == 0 disables the whole policy (WorkRules' documented
    /// convention), so the note must disappear with it.
    func testFamilyDayDisabledByRules() {
        var off = WorkRules()
        off.familyDayEarlyLeave = 0
        XCTAssertNil(TargetNote.compose(on: d(2026, 7, 31, 9, 12), rules: off, timeOff: [:]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TargetNoteTests`
Expected: compile failure — cannot find `TargetNote` in scope.

- [ ] **Step 3: Implement**

Create `Sources/KaltoeCore/WeekSummary.swift` with just this much for now:

```swift
import Foundation

/// Composes the popover's caption for a day whose target is shorter than usual.
///
/// The string is built here rather than per platform because the Linux tray is
/// Python and would otherwise carry a second copy of the wording, free to drift.
public enum TargetNote {
    /// "Target 4:00 · family day, time off", or nil when nothing shortened the day.
    public static func compose(on day: Date, rules: WorkRules, timeOff: [Date: TimeInterval],
                               calendar: Calendar = .current) -> String? {
        let off = WorkCalculator.timeOff(on: day, in: timeOff, calendar: calendar)
        let target = WorkCalculator.dailyTarget(on: day, rules: rules, timeOff: off,
                                                calendar: calendar)
        guard target < rules.dailyWork else { return nil }
        var reasons: [String] = []
        if rules.familyDayEarlyLeave > 0, WorkCalculator.isFamilyDay(day, calendar: calendar) {
            reasons.append("family day")
        }
        if off > 0 { reasons.append("time off") }
        // A reduced target with no nameable cause would render as a dangling
        // "Target 6:00 · ". Saying nothing is the better failure.
        guard !reasons.isEmpty else { return nil }
        return "Target \(Formatting.hm(target)) · " + reasons.joined(separator: ", ")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TargetNoteTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/WeekSummary.swift Tests/KaltoeCoreTests/WeekSummaryTests.swift
git commit -m "feat: compose the reduced-target caption in KaltoeCore

Family day and approved time off both shorten the day silently, and they can
stack. One composed string, shared by the popover and the Linux tray, so the
wording cannot drift between them."
```

---

### Task 3: `WeekSummary.compute` — the per-day model

**Files:**
- Modify: `Sources/KaltoeCore/WeekSummary.swift`
- Test: `Tests/KaltoeCoreTests/WeekSummaryTests.swift`

**Interfaces:**
- Consumes: `WorkCalculator.breakTaken` (Task 1), `TargetNote.compose` (Task 2), `WeekData.weekIncludingManual(now:)`, `WorkCalculator.weekStart(of:calendar:)`, `WorkCalculator.weeklyOvertime`, `WorkCalculator.dailyOvertime`, `WorkCalculator.breakDuration`, `WorkCalculator.dailyTarget`, `WorkCalculator.timeOff`.
- Produces:
  - `DaySummary` with public stored properties `date: Date`, `label: String`, `worked: TimeInterval?`, `target: TimeInterval`, `overtime: TimeInterval`, `isDayOff: Bool`, `isOngoing: Bool`, and a public memberwise `init`.
  - `WeekSummary` with `days: [DaySummary]`, `overtime: TimeInterval`, `cap: TimeInterval`, `targetNote: String?`, `todayIsDayOff: Bool`, and a public memberwise `init`.
  - `WeekSummary.compute(from:now:rules:calendar:) -> WeekSummary`.
  - Both types are `Equatable, Sendable`. `WeekSummary` is used by Tasks 4, 5 and 6; `DaySummary` by Tasks 5 and 6.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KaltoeCoreTests/WeekSummaryTests.swift`:

```swift
final class WeekSummaryTests: XCTestCase {
    /// The canonical week from the plan: Mon 8:35, Tue 9:10, Wed 7:40, Thu off,
    /// Fri open from 09:12 and a family day. Week OT = 1:45.
    private var week: WeekData {
        WeekData(
            records: [
                WorkRecord(clockIn: d(2026, 7, 27, 9, 0), clockOut: d(2026, 7, 27, 18, 35),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 28, 9, 0), clockOut: d(2026, 7, 28, 19, 10),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: d(2026, 7, 29, 17, 40),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 31, 9, 12), clockOut: nil, flexWorkedNet: nil),
            ],
            dayOffDates: [Calendar.current.startOfDay(for: d(2026, 7, 30, 0, 0))],
            timeOff: [:])
    }

    private let now = d(2026, 7, 31, 14, 41)

    private func summary(_ data: WeekData? = nil, now override: Date? = nil) -> WeekSummary {
        WeekSummary.compute(from: data ?? week, now: override ?? now, rules: rules)
    }

    func testAlwaysFiveWeekdayRowsInOrder() {
        XCTAssertEqual(summary().days.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri"])
    }

    /// Five rows even with no records at all — the strip must not collapse.
    func testFiveRowsWithAnEmptyWeek() {
        let empty = summary(WeekData())
        XCTAssertEqual(empty.days.count, 5)
        XCTAssertTrue(empty.days.allSatisfy { $0.worked == nil })
        XCTAssertEqual(empty.overtime, 0)
    }

    func testCompletedDaysDeductTheBreak() {
        let days = summary().days
        XCTAssertEqual(days[0].worked, 8 * 3600 + 35 * 60)   // 09:00–18:35 − 1h
        XCTAssertEqual(days[1].worked, 9 * 3600 + 10 * 60)
        XCTAssertEqual(days[2].worked, 7 * 3600 + 40 * 60)
    }

    /// Flex's own net figure wins when supplied, matching dailyOvertime.
    func testFlexNetWorkedIsPreferredWhenPresent() {
        let data = WeekData(records: [
            WorkRecord(clockIn: d(2026, 7, 27, 9, 0), clockOut: d(2026, 7, 27, 18, 35),
                       flexWorkedNet: 7 * 3600)
        ])
        XCTAssertEqual(summary(data).days[0].worked, 7 * 3600)
    }

    /// 09:12 to 14:41 is 5:29 elapsed, and lunch is fully spent by then, so 4:29.
    func testOngoingDayDeductsOnlyTheBreakAlreadyTaken() {
        XCTAssertEqual(summary().days[4].worked, 4 * 3600 + 29 * 60)
        XCTAssertTrue(summary().days[4].isOngoing)
    }

    /// The case breakTaken exists for: at 10:00 nothing has been deducted, so the
    /// bar shows 48 minutes rather than sitting at zero.
    func testOngoingDayBeforeLunchDeductsNothing() {
        let early = summary(now: d(2026, 7, 31, 10, 0))
        XCTAssertEqual(early.days[4].worked, 48 * 60)
    }

    func testDayOffIsMarkedAndHasNoWork() {
        let thursday = summary().days[3]
        XCTAssertTrue(thursday.isDayOff)
        XCTAssertNil(thursday.worked)
        XCTAssertFalse(thursday.isOngoing)
    }

    /// Friday is the last Friday of July, so its notch sits at 6h, not 8h.
    func testFamilyDayShortensOnlyItsOwnTarget() {
        let days = summary().days
        XCTAssertEqual(days[0].target, 8 * 3600)
        XCTAssertEqual(days[4].target, 6 * 3600)
    }

    func testTimeOffShortensThatDaysTarget() {
        var data = week
        data.timeOff = [Calendar.current.startOfDay(for: d(2026, 7, 29, 0, 0)): 2 * 3600]
        XCTAssertEqual(summary(data).days[2].target, 6 * 3600)
    }

    /// The property that lets the rows sit under the total without contradicting
    /// it, on an ordinary week. Short days floor at zero, exactly as weeklyOvertime
    /// counts them. `testPostLunchClockInStillAgreesWithTheTotal` is the case that
    /// actually stresses it.
    func testPerDayOvertimeSumsToTheWeeklyTotal() {
        let s = summary()
        XCTAssertEqual(s.days.map(\.overtime), [35 * 60, 70 * 60, 0, 0, 0])
        XCTAssertEqual(s.days.reduce(0) { $0 + $1.overtime }, s.overtime)
        XCTAssertEqual(s.overtime, 105 * 60)
        XCTAssertEqual(s.cap, rules.weeklyOvertimeCap)
    }

    func testTargetNoteReflectsToday() {
        XCTAssertEqual(summary().targetNote, "Target 6:00 · family day")
        // Wednesday is ordinary, so a Wednesday `now` has nothing to explain.
        XCTAssertNil(summary(now: d(2026, 7, 29, 15, 0)).targetNote)
    }

    func testTodayIsDayOffTracksTheDayOffSet() {
        XCTAssertFalse(summary().todayIsDayOff)
        XCTAssertTrue(summary(now: d(2026, 7, 30, 10, 0)).todayIsDayOff)
    }

    /// Regression test for a defect the plan originally shipped: deriving the row's
    /// overtime from `worked - target` diverges from the published total whenever the
    /// worker clocked in after lunch, because `breakTaken` is 0 while `leaveTime`
    /// still adds the whole break. 13:00 start, 8h target, due out 22:00; at 22:30 the
    /// naive form gives +1:30 and the total gives +0:30. They must agree.
    func testPostLunchClockInStillAgreesWithTheTotal() {
        let data = WeekData(records: [
            WorkRecord(clockIn: d(2026, 7, 29, 13, 0), clockOut: nil, flexWorkedNet: nil)
        ])
        let s = WeekSummary.compute(from: data, now: d(2026, 7, 29, 22, 30), rules: rules)
        XCTAssertEqual(s.days[2].overtime, 30 * 60)
        XCTAssertEqual(s.days[2].overtime, s.overtime)
        // The bar still measures actual time on the clock, break untaken.
        XCTAssertEqual(s.days[2].worked, 9 * 3600 + 30 * 60)
    }

    /// A manual start is a real record everywhere else, so it must appear as a row.
    func testManualStartAppearsAsARow() {
        SettingsStore.defaults = UserDefaults(suiteName: "weeksummary-\(UUID().uuidString)")!
        SettingsStore.setManualStart(d(2026, 7, 31, 9, 12), on: d(2026, 7, 31, 9, 12))
        let s = WeekSummary.compute(from: WeekData(), now: now, rules: rules)
        XCTAssertEqual(s.days[4].worked, 4 * 3600 + 29 * 60)
        XCTAssertTrue(s.days[4].isOngoing)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WeekSummaryTests`
Expected: compile failure — cannot find `WeekSummary` in scope.

- [ ] **Step 3: Implement**

Append to `Sources/KaltoeCore/WeekSummary.swift`:

```swift
/// One weekday in the week strip. Display-only: every field is derived, and
/// nothing here feeds the leave-time or overtime calculations.
public struct DaySummary: Equatable, Sendable {
    public var date: Date               // startOfDay
    public var label: String            // "Mon"
    public var worked: TimeInterval?    // nil = no record that day
    public var target: TimeInterval     // the bar's notch
    public var overtime: TimeInterval   // max(0, worked - target)
    public var isDayOff: Bool
    public var isOngoing: Bool

    public init(date: Date, label: String, worked: TimeInterval?, target: TimeInterval,
                overtime: TimeInterval, isDayOff: Bool, isOngoing: Bool) {
        self.date = date
        self.label = label
        self.worked = worked
        self.target = target
        self.overtime = overtime
        self.isDayOff = isDayOff
        self.isOngoing = isOngoing
    }
}

/// The whole week as the UI needs it, computed once per tick and consumed by the
/// menu bar pill, the popover and the daemon's status line — so the three cannot
/// disagree the way the popover and the pill previously could.
public struct WeekSummary: Equatable, Sendable {
    public var days: [DaySummary]        // always 5, Mon–Fri
    public var overtime: TimeInterval
    public var cap: TimeInterval
    public var targetNote: String?
    public var todayIsDayOff: Bool

    public init(days: [DaySummary] = [], overtime: TimeInterval = 0, cap: TimeInterval = 0,
                targetNote: String? = nil, todayIsDayOff: Bool = false) {
        self.days = days
        self.overtime = overtime
        self.cap = cap
        self.targetNote = targetNote
        self.todayIsDayOff = todayIsDayOff
    }

    /// Weekday labels, fixed rather than locale-derived: the rest of this UI is
    /// English ("Started", "Leave at"), so a localised strip would be the only
    /// translated text on screen.
    private static let labels = ["Mon", "Tue", "Wed", "Thu", "Fri"]

    public static func compute(from data: WeekData, now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> WeekSummary {
        // weekIncludingManual, not `records`, so a manual start appears as a row
        // exactly as it already counts toward the total.
        let records = data.weekIncludingManual(now: now)
        let weekStart = WorkCalculator.weekStart(of: now, calendar: calendar)
        let days = Self.labels.indices.map { offset -> DaySummary in
            let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            let key = calendar.startOfDay(for: day)
            let off = WorkCalculator.timeOff(on: day, in: data.timeOff, calendar: calendar)
            let target = WorkCalculator.dailyTarget(on: day, rules: rules, timeOff: off,
                                                    calendar: calendar)
            let record = records.first { calendar.isDate($0.clockIn, inSameDayAs: day) }
            let worked = record.map {
                netWorked($0, target: target, now: now, rules: rules, timeOff: off,
                          calendar: calendar)
            }
            return DaySummary(date: key, label: Self.labels[offset], worked: worked,
                              target: target,
                              // The same function that feeds weeklyOvertime, floored
                              // the same way, so a row cannot contradict the total
                              // printed beneath it. Deriving it from `worked` instead
                              // looks equivalent and is not: see netWorked below.
                              overtime: record.map {
                                  max(0, WorkCalculator.dailyOvertime(record: $0, now: now,
                                                                      rules: rules,
                                                                      timeOff: data.timeOff))
                              } ?? 0,
                              isDayOff: data.dayOffDates.contains(key),
                              isOngoing: record.map { $0.clockOut == nil } ?? false)
        }
        return WeekSummary(
            days: days,
            overtime: WorkCalculator.weeklyOvertime(records: records, timeOff: data.timeOff,
                                                    now: now, rules: rules),
            cap: rules.weeklyOvertimeCap,
            targetNote: TargetNote.compose(on: now, rules: rules, timeOff: data.timeOff,
                                           calendar: calendar),
            todayIsDayOff: days.first { calendar.isDate($0.date, inSameDayAs: now) }?
                .isDayOff ?? false)
    }

    /// Net hours worked — the bar's length and the row's right-hand figure only.
    /// Completed days mirror `dailyOvertime`'s derivation; open days deduct only the
    /// break already spent, so the figure rises from clock-in rather than starting an
    /// hour in the hole.
    ///
    /// **This is deliberately not the source of the row's overtime.** It is tempting
    /// to write `max(0, worked - target)` and call it the same thing, and it is not:
    /// clock in after the lunch window closes and `breakTaken` stays 0 forever while
    /// `leaveTime` still adds the full break. A 13:00 start with an 8h target is due
    /// out at 22:00, so at 22:30 `worked - target` reads +1:30 where `dailyOvertime`
    /// reads +0:30 — and the row would contradict the weekly total directly beneath
    /// it, which is the failure the signed-overtime layout was rejected to avoid.
    /// `overtime` therefore comes from `dailyOvertime` above.
    ///
    /// The consequence, accepted: the orange segment is drawn from `worked` against
    /// `target`, so after a late start it can lead the pill by up to the untaken
    /// break. The numbers stay consistent; only the sliver is early.
    private static func netWorked(_ record: WorkRecord, target: TimeInterval, now: Date,
                                  rules: WorkRules, timeOff: TimeInterval,
                                  calendar: Calendar) -> TimeInterval {
        if let out = record.clockOut {
            return record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn)
                          - WorkCalculator.breakDuration(target: target, rules: rules))
        }
        return max(0, now.timeIntervalSince(record.clockIn)
                      - WorkCalculator.breakTaken(clockIn: record.clockIn, now: now, rules: rules,
                                                  timeOff: timeOff, calendar: calendar))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter KaltoeCoreTests`
Expected: PASS. Every pre-existing `KaltoeCoreTests` case must still pass — nothing in this task changed shared behaviour.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/WeekSummary.swift Tests/KaltoeCoreTests/WeekSummaryTests.swift
git commit -m "feat: WeekSummary — the per-day week model

Five weekday rows with worked/target/overtime plus the weekly total, computed
in one place so the pill, the popover and the Linux status line all read from
the same numbers."
```

---

### Task 4: Publish the summary from `AppState.recompute`

Behaviour-neutral on screen; it moves the arithmetic off the view and out of the second pass. Closes follow-up item 10.

**Files:**
- Modify: `Sources/FlexTimer/AppState.swift` (property near `:12`, `recompute` at `:114-131`)
- Test: `Tests/FlexTimerTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `WeekSummary.compute(from:now:rules:)` (Task 3).
- Produces: `AppState.weekSummary: WeekSummary`, `@Published`, read by Task 5.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlexTimerTests/AppStateTests.swift`:

```swift
    /// The pill and the popover used to derive weekly overtime independently, so
    /// they could disagree. One published summary makes that impossible — this
    /// pins the agreement rather than the number.
    func testRecomputePublishesAWeekSummaryMatchingThePill() {
        let state = AppState()
        state.hasSession = true
        state.week = [
            WorkRecord(clockIn: d(2026, 7, 27, 9, 0), clockOut: d(2026, 7, 27, 18, 35),
                       flexWorkedNet: nil),
            WorkRecord(clockIn: d(2026, 7, 31, 9, 12), clockOut: nil, flexWorkedNet: nil),
        ]
        state.recompute(now: d(2026, 7, 31, 14, 41))

        XCTAssertEqual(state.weekSummary.days.count, 5)
        XCTAssertEqual(state.weekSummary.days.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri"])
        XCTAssertEqual(state.weekSummary.overtime, 35 * 60)  // Monday's +0:35 only
        XCTAssertEqual(state.weekSummary.days[4].worked, 4 * 3600 + 29 * 60)
        // 2026-07-31 is the last Friday of July.
        XCTAssertEqual(state.weekSummary.targetNote, "Target 6:00 · family day")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AppStateTests.testRecomputePublishesAWeekSummary`
Expected: compile failure — `AppState` has no member `weekSummary`.

- [ ] **Step 3: Implement**

Add the property after `timeOff` in `Sources/FlexTimer/AppState.swift`:

```swift
    /// Derived once per tick and published so the popover renders without
    /// computing anything. The popover used to derive weekly overtime itself on
    /// every body pass, which was both a second pass per second and a way for the
    /// pill and the popover to show different figures.
    @Published var weekSummary = WeekSummary()
```

Replace the body of `recompute(now:)` (`:114-131`) with:

```swift
    func recompute(now: Date) {
        let record = todayRecord(now: now)
        hookRunner?.evaluate(today: record, now: now)
        // Derived once and shared. This runs every second, and the display, the
        // notifier and the popover all need the same figures.
        let summary = WeekSummary.compute(from: weekData, now: now, rules: rules)
        weekSummary = summary
        let display = DisplayState.computeDisplay(hasSession: hasSession, today: record,
                                                  weeklyOvertime: summary.overtime,
                                                  timeOff: timeOff,
                                                  now: now, rules: rules)
        menuDisplay = display
        menuText = display.state.menuBarText
        limitNotifier?.evaluate(weeklyOvertime: summary.overtime,
                                clockedIn: record?.clockOut == nil && record != nil,
                                now: now, rules: rules)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FlexTimerTests`
Expected: PASS, including the existing pill assertions in `AppStateTests` — `summary.overtime` must be a drop-in for the deleted `weeklyOvertime` call.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/AppState.swift Tests/FlexTimerTests/AppStateTests.swift
git commit -m "refactor: publish WeekSummary from recompute

The popover computed weekly overtime on every body pass while recompute
computed it every second for the pill — two passes that could disagree
(follow-up 10). One published summary, derived once.

Closes follow-up 10."
```

---

### Task 5: The macOS week strip and caption

**Files:**
- Create: `Sources/FlexTimer/WeekBarRow.swift`
- Modify: `Sources/FlexTimer/MenuBarView.swift` (`information` at `:72-93`, `weekSummary` at `:123-139`)

**Interfaces:**
- Consumes: `AppState.weekSummary` (Task 4), `DaySummary` (Task 3), `Formatting.hm`.
- Produces: `WeekBarRow(day: DaySummary)`. No later task depends on it.

There are no view tests in this project and no snapshot harness, so this task is verified by build plus a real launch.

- [ ] **Step 1: Create the row view**

Create `Sources/FlexTimer/WeekBarRow.swift`:

```swift
import SwiftUI
import KaltoeCore

/// One day of the week strip: label, bar, hours worked.
///
/// The bar is blue up to the day's target and orange past it, with a notch at the
/// target, so each row carries its own overtime rather than only contributing to
/// the total below. Hours worked sits on the right; signed overtime would state
/// the orange segment's fact twice and cost track width.
struct WeekBarRow: View {
    let day: DaySummary

    /// Fixed rather than measured with a GeometryReader: the popover is a fixed
    /// 280pt, so 280 − 2×12 padding − 26 label − 36 value − 2×8 spacing = 178 is
    /// known here, and a reader would add a layout pass per row per second.
    private let trackWidth: CGFloat = 178
    private let trackHeight: CGFloat = 7
    /// Hours the full track spans, shared by every row so they are comparable.
    private let scale: TimeInterval = 10 * 3600

    var body: some View {
        HStack(spacing: 8) {
            Text(day.label)
                .font(.caption)
                .foregroundStyle(day.isOngoing ? Color.accentColor : Color.secondary)
                .frame(width: 26, alignment: .leading)
            track
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .opacity(day.worked == nil ? 0.55 : 1)
        // One element with one sentence, or VoiceOver reads a label, an unnamed
        // shape and a bare number as three stops. The orange segment is the only
        // place overtime appears on screen, so it has to be spoken here.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
                .frame(width: trackWidth, height: trackHeight)
            if let worked = day.worked {
                // Today's remaining target, as an outline the fill grows into.
                if day.isOngoing {
                    Capsule()
                        .strokeBorder(Color.secondary.opacity(0.45),
                                      style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: x(day.target), height: trackHeight)
                }
                Capsule().fill(Color.accentColor.opacity(day.isOngoing ? 0.55 : 1))
                    .frame(width: x(min(worked, day.target)), height: trackHeight)
                if day.overtime > 0 {
                    Capsule().fill(Color.orange)
                        .frame(width: x(day.overtime), height: trackHeight)
                        .offset(x: x(day.target))
                }
            }
            Rectangle().fill(Color.secondary)
                .frame(width: 1, height: trackHeight + 6)
                .offset(x: x(day.target))
        }
        .frame(width: trackWidth, height: trackHeight)
    }

    private var value: String {
        if let worked = day.worked { return Formatting.hm(worked) }
        return day.isDayOff ? "off" : "·"
    }

    private var spokenLabel: String {
        guard let worked = day.worked else {
            return day.isDayOff ? "\(day.label), day off" : "\(day.label), no record"
        }
        var text = "\(day.label), worked \(Formatting.hm(worked))"
        if day.overtime > 0 { text += ", \(Formatting.hm(day.overtime)) over target" }
        if day.isOngoing { text += ", still on the clock" }
        return text
    }

    /// Track offset for an interval, clamped to the track.
    private func x(_ interval: TimeInterval) -> CGFloat {
        min(trackWidth, max(0, trackWidth * CGFloat(interval / scale)))
    }
}
```

Note the one deliberate departure from the mockup: today's fill is the accent colour at 55% opacity rather than diagonal stripes. SwiftUI has no cheap striped fill, and a `Canvas` or repeating gradient for a 7pt capsule is not worth the code. The dashed outline still carries "in progress".

- [ ] **Step 2: Add the caption and the "Day off" state**

In `Sources/FlexTimer/MenuBarView.swift`, replace the body of `information(_:)` (`:72-93`) with:

```swift
    @ViewBuilder private func information(_ today: WorkRecord?) -> some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            if case .onBreak = state.menuDisplay.state {
                row("Back at", WorkCalculator.lunchWindow(on: Date(), rules: state.rules).endAt
                    .formatted(date: .omitted, time: .shortened))
            }
            if let today, state.hasSession {
                let off = WorkCalculator.timeOff(on: today.clockIn, in: state.timeOff)
                row("Started", today.clockIn.formatted(date: .omitted, time: .shortened))
                row("Leave at", WorkCalculator.leaveTime(clockIn: today.clockIn, rules: state.rules,
                                                         timeOff: off)
                    .formatted(date: .omitted, time: .shortened))
                // Only present when something shortened the day. Family day and
                // approved time off both move Leave at with no other explanation,
                // and when they stack the break vanishes too, so the row moves
                // five hours rather than the four the target change alone implies.
                if let note = state.weekSummary.targetNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                row("Time left", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules, timeOff: off)))
            } else if state.hasSession {
                Text(state.weekSummary.todayIsDayOff ? "Day off" : "Not clocked in yet")
                    .foregroundStyle(.secondary)
            } else {
                Text("Session expired").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }
```

- [ ] **Step 3: Add the week strip**

Replace `weekSummary` (`:123-139`) with:

```swift
    private var weekSummary: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Rendered whenever the week holds any record, signed out included —
            // the same rule Week OT already followed, so stale-but-real data stays
            // on screen instead of blanking.
            if state.weekSummary.days.contains(where: { $0.worked != nil }) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.weekSummary.days, id: \.date) { WeekBarRow(day: $0) }
                }
            }
            row("Week OT", "\(Formatting.hm(state.weekSummary.overtime)) / "
                + Formatting.hm(state.weekSummary.cap))
            if let error = state.syncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let sync = state.lastSync {
                Text("Synced \(sync.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }
```

`WorkCalculator.weeklyOvertime` and `state.weekIncludingManual` are now unused here — confirm neither remains in the file.

- [ ] **Step 4: Build clean and run the app**

```bash
rm -rf .build && swift build --build-tests 2>&1 | grep -E "warning|error" ; swift test
```
Expected: no warnings, no errors, all tests pass.

Then launch and look at the popover:
```bash
./scripts/bundle.sh && open ./build/FlexTimer.app 2>/dev/null || swift run FlexTimer
```
Check, with a real session: five weekday rows appear; today's row is accent-coloured with a dashed outline ahead of its fill; a day past target shows orange beyond the notch; the day-off row reads `off` and is dimmed; nothing overflows 280pt. On the last Friday of a month, or a day with approved time off, the caption appears under `Leave at`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/WeekBarRow.swift Sources/FlexTimer/MenuBarView.swift
git commit -m "feat: week strip and reduced-target caption in the popover

Five weekday bars, blue to the day's target and orange past it, with hours
worked on the right. A caption under Leave at whenever family day or approved
time off shortened the day, and Day off in place of Not clocked in yet when
today is one — the first use of dayOffDates, which has been fetched and
discarded since it was parsed."
```

---

### Task 6: Ship the summary over NDJSON

**Files:**
- Modify: `Sources/KaltoeCore/StatusLine.swift`, `Sources/KaltoeDaemon/HeadlessState.swift:47-70`
- Test: `Tests/KaltoeDaemonTests/HeadlessStateTests.swift`

**Interfaces:**
- Consumes: `WeekSummary` and `DaySummary` (Task 3).
- Produces: `StatusLine.days: [StatusLine.DayLine]?`, `StatusLine.targetNote: String?`, `StatusLine.weekOvertimeCap: Int?`, and a `summary: WeekSummary?` parameter on `StatusLine.init`. Consumed by Task 7 as JSON.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KaltoeDaemonTests/HeadlessStateTests.swift`. The existing `page` fixture is a single open Wednesday record; these need the fuller week, so add a second fixture inside the class:

```swift
    /// The canonical week, for the fields the tray's new rows read. Thursday is a
    /// day off; Friday 2026-07-31 is open and is the last Friday of July.
    private var fullWeek: ParseResult {
        ParseResult(
            records: [
                WorkRecord(clockIn: d(2026, 7, 27, 9, 0), clockOut: d(2026, 7, 27, 18, 35),
                           flexWorkedNet: nil),
                WorkRecord(clockIn: d(2026, 7, 31, 9, 12), clockOut: nil, flexWorkedNet: nil),
            ],
            dayOffDates: [Calendar.current.startOfDay(for: d(2026, 7, 30, 0, 0))],
            timeOff: [:])
    }

    func testStatusLineCarriesThePerDayRows() async throws {
        let state = state([.success(fullWeek)])
        await state.refresh()

        let line = state.status(now: d(2026, 7, 31, 14, 41))
        let days = try XCTUnwrap(line.days)
        XCTAssertEqual(days.count, 5)
        XCTAssertEqual(days.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri"])
        XCTAssertEqual(days[0].worked, 8 * 3600 + 35 * 60)
        XCTAssertEqual(days[0].overtime, 35 * 60)
        XCTAssertNil(days[2].worked)                       // no Wednesday record
        XCTAssertTrue(days[3].isDayOff)                    // Thursday
        XCTAssertTrue(days[4].isOngoing)                   // Friday, still clocked in
        XCTAssertEqual(days[4].target, 6 * 3600)           // family day
        XCTAssertEqual(line.targetNote, "Target 6:00 · family day")
        XCTAssertEqual(line.weekOvertimeCap, 12 * 3600)
    }

    /// Seconds would make the daemon emit every second instead of every minute
    /// (main.swift emits on change), so every interval is minute-truncated.
    func testPerDayIntervalsAreTruncatedToWholeMinutes() async {
        let state = state([.success(fullWeek)])
        await state.refresh()

        // 09:12 to 14:41:37 is 5:29:37 elapsed, less the full hour of lunch.
        let line = state.status(now: d(2026, 7, 31, 14, 41).addingTimeInterval(37))
        XCTAssertEqual(line.days?[4].worked, 4 * 3600 + 29 * 60)
        XCTAssertEqual(line.days?.allSatisfy { ($0.worked ?? 0) % 60 == 0 }, true)
    }

    /// Mirrors the existing gate on started/leaveAt/weekOvertime: refreshing
    /// successfully first is what makes nil discriminating.
    func testSessionExpiredGatesTheNewFieldsToo() async {
        let state = state([.success(fullWeek), .failure(FlexClient.FlexError.sessionExpired)])
        await state.refresh()
        await state.refresh()

        XCTAssertFalse(state.hasSession)
        XCTAssertEqual(state.weekData.records.count, 2, "week data must survive, or nil proves nothing")

        let line = state.status(now: d(2026, 7, 31, 14, 41))
        XCTAssertNil(line.days)
        XCTAssertNil(line.targetNote)
        XCTAssertNil(line.weekOvertimeCap)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HeadlessStateTests`
Expected: compile failure — `StatusLine` has no member `days`.

- [ ] **Step 3: Implement**

In `Sources/KaltoeCore/StatusLine.swift`, add the fields after `weekOvertime` and extend the initialiser:

```swift
    /// The week strip, minute-truncated. Omitted when signed out, like the rows above.
    public var days: [DayLine]?
    /// "Target 4:00 · family day, time off" — nil unless today's target is reduced.
    public var targetNote: String?
    /// The weekly overtime ceiling, so the tray can render "/ 12:00" as the
    /// popover does rather than a bare total.
    public var weekOvertimeCap: Int?

    /// One weekday for the tray. Intervals are whole seconds truncated to the
    /// minute: `main.swift` emits on change, so a second-resolution `worked` for
    /// the ongoing day would turn a once-per-minute emission into once per second —
    /// and on Plasma every emission drives a full tray-icon re-render.
    public struct DayLine: Codable, Equatable, Sendable {
        public var label: String
        public var worked: Int?
        public var target: Int
        public var overtime: Int
        public var isDayOff: Bool
        public var isOngoing: Bool

        init(_ day: DaySummary) {
            label = day.label
            worked = day.worked.map { Int($0 / 60) * 60 }
            target = Int(day.target / 60) * 60
            overtime = Int(day.overtime / 60) * 60
            isDayOff = day.isDayOff
            isOngoing = day.isOngoing
        }
    }
```

Extend the initialiser signature and body:

```swift
    public init(display: MenuDisplay, hasSession: Bool, lastSync: Date?, syncError: String?,
                started: Date? = nil, leaveAt: Date? = nil, weekOvertime: TimeInterval? = nil,
                summary: WeekSummary? = nil) {
```

and append to its body:

```swift
        self.days = summary?.days.map(DayLine.init)
        self.targetNote = summary?.targetNote
        self.weekOvertimeCap = summary.map { Int($0.cap / 60) * 60 }
```

In `Sources/KaltoeDaemon/HeadlessState.swift`, replace the `weekly` derivation and the return in `status(now:)` so the summary is built once and reused:

```swift
    func status(now: Date) -> StatusLine {
        let today = weekData.todayRecord(now: now)
        let rules = SettingsStore.rules
        // One computation feeds the display's cap check, the status line's own
        // total, and the tray's per-day rows.
        let summary = WeekSummary.compute(from: weekData, now: now, rules: rules)
        let display = DisplayState.computeDisplay(hasSession: hasSession,
                                                  today: today,
                                                  weeklyOvertime: summary.overtime,
                                                  timeOff: weekData.timeOff,
                                                  now: now, rules: rules)
        var leaveAt: Date?
        if hasSession, let today {
            let off = WorkCalculator.timeOff(on: today.clockIn, in: weekData.timeOff)
            leaveAt = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules, timeOff: off)
        }
        return StatusLine(display: display, hasSession: hasSession,
                          lastSync: lastSync, syncError: syncError,
                          started: hasSession ? today?.clockIn : nil,
                          leaveAt: leaveAt,
                          weekOvertime: hasSession ? summary.overtime : nil,
                          summary: hasSession ? summary : nil)
    }
```

The local `week` binding and the `WorkCalculator.weeklyOvertime` call are now unused — remove both.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS, all targets. The four pre-existing `HeadlessStateTests` cases must still pass — `summary.overtime` is a drop-in for the removed `weeklyOvertime` call.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/StatusLine.swift Sources/KaltoeDaemon/HeadlessState.swift \
        Tests/KaltoeDaemonTests/HeadlessStateTests.swift
git commit -m "feat: ship the week strip over NDJSON

days, targetNote and weekOvertimeCap on StatusLine, gated on hasSession like
the rows already there. Intervals are minute-truncated so the daemon keeps
emitting on the minute rather than every second.

weekOvertimeCap closes the StatusLine half of follow-up 2."
```

---

### Task 7: The Linux tray rows

**Files:**
- Create: `linux/kaltoe_rows.py`
- Modify: `linux/kaltoe-tray.py` (`_build_menu` at `:146-196`, `apply_status` at `:287-336`), `linux/install.sh:8`

**Interfaces:**
- Consumes: the JSON produced in Task 6 — `days` (a list of `{label, worked, target, overtime, isDayOff, isOngoing}`), `targetNote`, `weekOvertimeCap`.
- Produces: nothing consumed by later tasks.

The tray shows figures, not bars: rows are `Gtk.MenuItem` labels serialised over DBusMenu, which carries text, icons and checkmarks but not custom widgets. The cairo/Pango code already in this file renders the *tray icon* PNG, a different path. Because there is no bar, these rows do carry signed overtime.

- [ ] **Step 1: Write the formatter with its check**

`kaltoe-tray.py` raises `SystemExit` at import time when GTK introspection is missing, so its formatting cannot be exercised on a machine without GTK. Put the pure part in its own importable module — the filename has no hyphen precisely so it can be imported.

Create `linux/kaltoe_rows.py`:

```python
"""Label formatting for the tray's week rows.

Split out of kaltoe-tray.py so it imports without GTK: that module raises
SystemExit at import time when the introspection data is missing, which makes
its formatting untestable anywhere but a configured Linux desktop.
"""


def hm(seconds):
    """'8:35' — whole minutes, negatives clamped. Mirrors Formatting.hm."""
    minutes = max(0, int(seconds)) // 60
    return f"{minutes // 60}:{minutes % 60:02d}"


def day_label(day):
    """One week row: 'Mon   8:35   +0:35', or 'Fri   4:29   · today'.

    Overtime is spelled out here because, unlike the macOS popover, there is no
    bar to carry it — DBusMenu serialises labels only.
    """
    worked = day.get("worked")
    if worked is None:
        return f"{day['label']}   off" if day.get("isDayOff") else day["label"]
    parts = [day["label"], hm(worked)]
    if day.get("overtime"):
        parts.append(f"+{hm(day['overtime'])}")
    if day.get("isOngoing"):
        parts.append("· today")
    return "   ".join(parts)
```

- [ ] **Step 2: Run the check to verify the formatter**

```bash
python3 - <<'EOF'
import sys; sys.path.insert(0, "linux")
from kaltoe_rows import day_label, hm

cases = [
    ({"label": "Mon", "worked": 30900, "overtime": 2100, "isDayOff": False, "isOngoing": False},
     "Mon   8:35   +0:35"),
    ({"label": "Wed", "worked": 27600, "overtime": 0, "isDayOff": False, "isOngoing": False},
     "Wed   7:40"),
    ({"label": "Thu", "worked": None, "overtime": 0, "isDayOff": True, "isOngoing": False},
     "Thu   off"),
    ({"label": "Fri", "worked": 16140, "overtime": 0, "isDayOff": False, "isOngoing": True},
     "Fri   4:29   · today"),
    ({"label": "Tue", "worked": None, "overtime": 0, "isDayOff": False, "isOngoing": False},
     "Tue"),
]
for day, expected in cases:
    got = day_label(day)
    assert got == expected, f"{got!r} != {expected!r}"
assert hm(-5) == "0:00" and hm(43200) == "12:00"
print(f"{len(cases) + 1} cases pass")
EOF
```
Expected: `6 cases pass`.

- [ ] **Step 3: Wire the rows into the menu**

In `linux/kaltoe-tray.py`, add the import beside the stdlib imports at the top (it is GTK-free, so it is safe above the `gi` block):

```python
from kaltoe_rows import day_label, hm
```

Since the tray is launched by absolute path from the autostart entry, make sure its own directory is importable — add directly above that import:

```python
sys.path.insert(0, str(Path(__file__).resolve().parent))
```

In `_build_menu`, insert the caption item straight after `self.leave_item` is appended:

```python
        self.target_item = Gtk.MenuItem(label="")
        self.target_item.set_sensitive(False)
        menu.append(self.target_item)
```

and the week block between `self.timeleft_item` and `self.ot_item`:

```python
        self.day_separators = [Gtk.SeparatorMenuItem(), Gtk.SeparatorMenuItem()]
        menu.append(self.day_separators[0])
        self.day_items = []
        for _ in range(5):
            item = Gtk.MenuItem(label="")
            item.set_sensitive(False)
            menu.append(item)
            self.day_items.append(item)
        menu.append(self.day_separators[1])
```

Extend the hide-on-startup loop near the end of `_build_menu` — it currently lists four items — to cover the new ones:

```python
        for item in (self.started_item, self.leave_item, self.target_item,
                     self.timeleft_item, self.ot_item,
                     *self.day_items, *self.day_separators):
            item.hide()
```

- [ ] **Step 4: Populate them in `apply_status`**

Replace the `week_ot` block in `apply_status` (the four lines from `self.ot_item.set_visible(...)`) with:

```python
        self.ot_item.set_visible(week_ot is not None)
        if week_ot is not None:
            label = f"Week OT {self._signed_hm(week_ot)}"
            cap = status.get("weekOvertimeCap")
            if cap is not None:
                label += f" / {hm(cap)}"
            self.ot_item.set_label(label)

        note = status.get("targetNote")
        self.target_item.set_visible(bool(note))
        if note:
            self.target_item.set_label("  " + note)

        days = status.get("days") or []
        for item, day in zip(self.day_items, days):
            item.set_label(day_label(day))
            item.set_visible(True)
        for item in self.day_items[len(days):]:
            item.set_visible(False)
        for separator in self.day_separators:
            separator.set_visible(bool(days))
```

Also add `self.target_item` and the new items to the hide list in `on_core_dead`, which currently names four:

```python
        for item in (self.started_item, self.leave_item, self.target_item,
                     self.timeleft_item, self.ot_item,
                     *self.day_items, *self.day_separators):
            item.hide()
```

- [ ] **Step 5: Add the new module to the installer**

`install.sh` copies files by name, so omitting this ships a tray that dies with `ModuleNotFoundError` on every Linux user's next login. Change `linux/install.sh:8` to:

```bash
cp kaltoe-core kaltoe-tray.py kaltoe_rows.py README-linux.md "$DEST/"
```

- [ ] **Step 6: Verify the daemon and tray agree**

Confirm the daemon really emits the new fields, and that the tray's formatter reads them:

```bash
./scripts/build-linux.sh
docker run --rm -v "$PWD:/w" -w /w swift:6.1-noble bash -c '
  (sleep 4 | .build-linux/x86_64-unknown-linux-gnu/release/kaltoe-core) | head -2' \
  | tail -1 | python3 -c '
import json, sys
sys.path.insert(0, "linux")
from kaltoe_rows import day_label
line = json.loads(sys.stdin.read())
print("hasSession:", line.get("hasSession"))
for day in line.get("days") or []:
    print(day_label(day))
print("no days field — expected when the container has no session"
      if not line.get("days") else "")'
```
Expected: valid JSON parses, and with no session in the container `days` is absent — which is itself the gate from Task 6 working. On a machine with a real session, five labelled rows print.

Then, on the Linux desktop, install and confirm visually:
```bash
cd linux && ./install.sh && ~/.local/share/kaltoe-timer/kaltoe-tray.py
```
Check: five day rows with separators, the caption row indented under `Leave at` on a shortened day, `Week OT +1:45 / 12:00`, and every one of them gone after `Restart core` fails. **This is also where to confirm the DBusMenu assumption** — if a custom widget does survive on this panel, say so, because it would reopen the bars-versus-figures choice.

- [ ] **Step 7: Commit**

```bash
git add linux/kaltoe_rows.py linux/kaltoe-tray.py linux/install.sh
git commit -m "feat: week rows in the Linux tray menu

The same per-day data as the macOS popover, as figures with signed overtime —
tray rows are DBusMenu labels, which carry no custom widgets, so there is no
bar to carry the overtime instead. Week OT gains the cap denominator.

Formatting lives in kaltoe_rows.py so it imports without GTK and can be
checked off a Linux desktop."
```

---

## Final verification

- [ ] **Clean build, both toolchains, warnings gated**

```bash
rm -rf .build && swift build --build-tests 2>&1 | grep -E "warning|error"
swift test
rm -rf .build-linux && ./scripts/build-linux.sh
```
Expected: no warnings, no errors, all tests pass. Run the clean build **once** — a warm rebuild re-emits nothing, which is how four real actor-isolation warnings reached final review previously.

- [ ] **Update the READMEs**

`README.md` and `linux/README-linux.md` both document the popover and tray contents. Add the week strip, the caption, and the tray's new rows. Note in `README.md` that the strip is Monday–Friday and that weekend work is excluded by design, pointing at follow-up 23.

- [ ] **Commit the docs**

```bash
git add README.md linux/README-linux.md
git commit -m "docs: describe the week strip and the reduced-target caption"
```
