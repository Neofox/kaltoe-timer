# FlexTimer v2 (Day Phases + Overwork Warning) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase-aware menu bar — countdown to lunch (11:20), BREAK mode until 12:30, then the existing leave countdown — plus an orange/red warning pill as leave time approaches.

**Architecture:** Extends v1's pure logic layer: `WorkRules` gains lunch fields, `WorkCalculator` gains `lunchWindow`, and `DisplayState` gains two phase cases plus a `MenuDisplay {state, urgency}` result. UI maps state → SF Symbol and urgency → capsule pill (white content on orange/red); pill labels render via `ImageRenderer` (menu bar labels are template-rendered, so plain `foregroundStyle` doesn't color them).

**Tech Stack:** Swift 5.9+/SwiftUI/SPM, zero third-party deps (unchanged from v1).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-09-flextimer-v2-phases-design.md`. Base repo state: v1 merged at `master` (all 40 tests green).
- Lunch defaults: official start 11:30, end 12:30, early-leave allowance 10 min → lunch-leave 11:20. UserDefaults keys exactly: `lunchStartMinutes` (690), `lunchEndMinutes` (750), `lunchEarlyLeaveMinutes` (10).
- Menu bar copy: toLunch = plain `H:MM` countdown to 11:20; onBreak = `BREAK H:MM` countdown to 12:30; counting/OT/no-session/not-clocked-in copy unchanged from v1.
- Icons: toLunch `fork.knife`, onBreak `cup.and.saucer`, everything else `timer`.
- Urgency: warning ≤ 30 min to leave (orange), critical ≤ 10 min or past leave while clocked in (red); lunch phases, clocked-out OT, not-clocked-in, no-session always normal. Thresholds are constants.
- Warning/critical rendering: a capsule PILL — orange/red background, WHITE icon + text — not tinted text. Normal state stays the plain template icon + text.
- Leave-time and overtime math untouched — lunch phases are display only.
- Phases only when still ahead; degenerate guard: if leave time ≤ lunch end, skip lunch phases.
- All new date tests pin a Seoul calendar (existing `d(...)` helper + explicit `calendar` parameter).

---

### Task 1: Lunch rules — WorkRules fields, lunchWindow, SettingsStore keys (TDD)

**Files:**

- Modify: `Sources/FlexTimer/WorkCalculator.swift` (WorkRules struct + new function)
- Modify: `Sources/FlexTimer/SettingsStore.swift:8-14` (rules computed property)
- Test: `Tests/FlexTimerTests/WorkCalculatorTests.swift` (append)
- Test: `Tests/FlexTimerTests/SettingsStoreTests.swift` (append)

**Interfaces:**

- Consumes: existing `WorkRules`, `SettingsStore.rules`.
- Produces (used by Tasks 2–3):
    - `WorkRules.lunchStart: TimeInterval` (seconds from midnight, default `41400` = 11:30)
    - `WorkRules.lunchEnd: TimeInterval` (default `45000` = 12:30)
    - `WorkRules.lunchEarlyLeave: TimeInterval` (default `600`)
    - `WorkCalculator.lunchWindow(on day: Date, rules: WorkRules, calendar: Calendar = .current) -> (leaveAt: Date, endAt: Date)`

- [ ] **Step 1: Write the failing tests**

Append to the `WorkCalculatorTests` class in `Tests/FlexTimerTests/WorkCalculatorTests.swift`:

```swift
    func testLunchWindowDefaults() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let window = WorkCalculator.lunchWindow(on: d(2026, 7, 9, 14, 0), rules: rules, calendar: cal)
        XCTAssertEqual(window.leaveAt, d(2026, 7, 9, 11, 20)) // 11:30 − 10 min allowance
        XCTAssertEqual(window.endAt, d(2026, 7, 9, 12, 30))
    }

    func testLunchWindowCustomRules() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var r = WorkRules()
        r.lunchStart = 12 * 3600      // 12:00
        r.lunchEnd = 13 * 3600        // 13:00
        r.lunchEarlyLeave = 0
        let window = WorkCalculator.lunchWindow(on: d(2026, 7, 9, 9, 0), rules: r, calendar: cal)
        XCTAssertEqual(window.leaveAt, d(2026, 7, 9, 12, 0))
        XCTAssertEqual(window.endAt, d(2026, 7, 9, 13, 0))
    }
```

Append to the `SettingsStoreTests` class in `Tests/FlexTimerTests/SettingsStoreTests.swift`:

```swift
    func testDefaultLunchRules() {
        let r = SettingsStore.rules
        XCTAssertEqual(r.lunchStart, 690 * 60)
        XCTAssertEqual(r.lunchEnd, 750 * 60)
        XCTAssertEqual(r.lunchEarlyLeave, 10 * 60)
    }

    func testOverriddenLunchRules() {
        SettingsStore.defaults.set(720.0, forKey: "lunchStartMinutes")
        SettingsStore.defaults.set(780.0, forKey: "lunchEndMinutes")
        SettingsStore.defaults.set(0.0, forKey: "lunchEarlyLeaveMinutes")
        let r = SettingsStore.rules
        XCTAssertEqual(r.lunchStart, 720 * 60)
        XCTAssertEqual(r.lunchEnd, 780 * 60)
        XCTAssertEqual(r.lunchEarlyLeave, 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `WorkRules` has no member `lunchStart` / `WorkCalculator` has no member `lunchWindow`.

- [ ] **Step 3: Implement**

In `Sources/FlexTimer/WorkCalculator.swift`, extend `WorkRules`:

```swift
struct WorkRules: Codable, Equatable {
    var dailyWork: TimeInterval = 8 * 3600       // net work target per day
    var breakTime: TimeInterval = 1 * 3600       // fixed lunch break
    var weeklyOvertime: TimeInterval = 5 * 3600  // required overtime per week
    var lunchStart: TimeInterval = 690 * 60      // official break start, seconds from midnight (11:30)
    var lunchEnd: TimeInterval = 750 * 60        // break end / work resumes (12:30)
    var lunchEarlyLeave: TimeInterval = 10 * 60  // allowed early departure to lunch
}
```

and add to the `WorkCalculator` enum:

```swift
    /// The lunch window on `day`: (moment you may leave for lunch, moment work resumes).
    /// Display only — does not affect leave time or overtime math.
    static func lunchWindow(on day: Date, rules: WorkRules,
                            calendar: Calendar = .current) -> (leaveAt: Date, endAt: Date) {
        let midnight = calendar.startOfDay(for: day)
        return (midnight.addingTimeInterval(rules.lunchStart - rules.lunchEarlyLeave),
                midnight.addingTimeInterval(rules.lunchEnd))
    }
```

In `Sources/FlexTimer/SettingsStore.swift`, extend the `rules` property (after the existing three `if let` lines):

```swift
        if let m = defaults.object(forKey: "lunchStartMinutes") as? Double { r.lunchStart = m * 60 }
        if let m = defaults.object(forKey: "lunchEndMinutes") as? Double { r.lunchEnd = m * 60 }
        if let m = defaults.object(forKey: "lunchEarlyLeaveMinutes") as? Double { r.lunchEarlyLeave = m * 60 }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all pass (40 existing + 4 new = 44).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: lunch window rules and settings keys"
```

---

### Task 2: DisplayState phases + MenuDisplay/Urgency (TDD)

**Files:**

- Modify: `Sources/FlexTimer/DisplayState.swift` (whole file evolves — full replacement below)
- Test: `Tests/FlexTimerTests/FormattingTests.swift` (append a new test class)

**Interfaces:**

- Consumes: Task 1's `lunchWindow` + lunch fields; existing `WorkCalculator`, `Formatting`.
- Produces (used by Task 3):
    - `enum Urgency: Equatable { case normal, warning, critical }`
    - `struct MenuDisplay: Equatable { var state: DisplayState; var urgency: Urgency }`
    - `DisplayState.computeDisplay(hasSession:today:week:now:rules:calendar:) -> MenuDisplay`
    - `DisplayState` cases `.toLunch(timeLeft:)`, `.onBreak(timeLeft:)` (plus v1's four)
    - `DisplayState.menuBarText` handles the new cases; `DisplayState.iconName: String`
    - v1's `DisplayState.compute(...) -> DisplayState` KEPT as a thin wrapper returning `.state` (existing tests/callers keep compiling)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlexTimerTests/FormattingTests.swift` (new class at file end; `d(...)` helper and `rules` exist in the test target):

```swift
final class PhaseDisplayTests: XCTestCase {
    let rules = WorkRules()
    var seoul: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }

    func display(_ clockIn: Date, _ now: Date, clockOut: Date? = nil,
                 r: WorkRules? = nil) -> MenuDisplay {
        let today = WorkRecord(clockIn: clockIn, clockOut: clockOut, flexWorkedNet: nil)
        return DisplayState.computeDisplay(hasSession: true, today: today, week: [today],
                                           now: now, rules: r ?? rules, calendar: seoul)
    }

    // Phase boundaries: clock-in 09:00 → lunch-leave 11:20, lunch-end 12:30, leave 18:00
    func testMorningCountsDownToLunchLeave() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 9, 30))
        XCTAssertEqual(s, MenuDisplay(state: .toLunch(timeLeft: 6600), urgency: .normal)) // 1h50 to 11:20
        XCTAssertEqual(s.state.menuBarText, "1:50")
        XCTAssertEqual(s.state.iconName, "fork.knife")
    }

    func testBoundary1119IsToLunch() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 19)).state,
                       .toLunch(timeLeft: 60))
    }

    func testBoundary1120IsOnBreak() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 20))
        XCTAssertEqual(s, MenuDisplay(state: .onBreak(timeLeft: 4200), urgency: .normal)) // 1:10 to 12:30
        XCTAssertEqual(s.state.menuBarText, "BREAK 1:10")
        XCTAssertEqual(s.state.iconName, "cup.and.saucer")
    }

    func testBoundary1229IsOnBreak() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 12, 29)).state,
                       .onBreak(timeLeft: 60))
    }

    func testBoundary1230IsCounting() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 12, 30)).state,
                       .counting(timeLeft: 5 * 3600 + 30 * 60)) // to 18:00
    }

    func testLateClockInDuringLunchIsOnBreak() {
        XCTAssertEqual(display(d(2026, 7, 9, 11, 25), d(2026, 7, 9, 11, 26)).state,
                       .onBreak(timeLeft: 64 * 60))
    }

    func testAfternoonClockInSkipsLunchPhases() {
        XCTAssertEqual(display(d(2026, 7, 9, 13, 0), d(2026, 7, 9, 14, 0)).state,
                       .counting(timeLeft: 8 * 3600)) // leave 22:00
    }

    func testDegenerateEarlyDaySkipsLunchPhases() {
        // clock-in 02:00 → leave 11:00 ≤ lunch end 12:30 → no lunch phases
        XCTAssertEqual(display(d(2026, 7, 9, 2, 0), d(2026, 7, 9, 9, 0)).state,
                       .counting(timeLeft: 2 * 3600))
    }

    func testCustomLunchRulesShiftBoundaries() {
        var r = WorkRules()
        r.lunchStart = 12 * 3600; r.lunchEnd = 13 * 3600; r.lunchEarlyLeave = 0
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 11, 30), r: r).state,
                       .toLunch(timeLeft: 30 * 60))
    }

    // Urgency: leave 18:00
    func testUrgencySteps() {
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 29)).urgency, .normal)   // 31 min
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 30)).urgency, .warning)  // 30 min
        XCTAssertEqual(display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 17, 50)).urgency, .critical) // 10 min
    }

    func testPastLeaveStillClockedInIsCritical() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 18, 5))
        XCTAssertEqual(s.urgency, .critical)
        if case .overtime = s.state {} else { XCTFail("expected overtime state") }
    }

    func testClockedOutOvertimeIsNormal() {
        let s = display(d(2026, 7, 9, 9, 0), d(2026, 7, 9, 18, 10), clockOut: d(2026, 7, 9, 18, 5))
        XCTAssertEqual(s.urgency, .normal)
        if case .overtime = s.state {} else { XCTFail("expected overtime state") }
    }

    func testNoSessionAndNotClockedInAreNormalWithTimerIcon() {
        let none = DisplayState.computeDisplay(hasSession: false, today: nil, week: [],
                                               now: d(2026, 7, 9, 9, 0), rules: rules, calendar: seoul)
        XCTAssertEqual(none, MenuDisplay(state: .noSession, urgency: .normal))
        XCTAssertEqual(DisplayState.counting(timeLeft: 60).iconName, "timer")
        XCTAssertEqual(DisplayState.overtime(weekly: 0).iconName, "timer")
        XCTAssertEqual(DisplayState.noSession.iconName, "timer")
        XCTAssertEqual(DisplayState.notClockedIn.iconName, "timer")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `cannot find 'MenuDisplay'`, no member `computeDisplay`.

- [ ] **Step 3: Implement — replace `Sources/FlexTimer/DisplayState.swift` with:**

```swift
import Foundation

enum Urgency: Equatable {
    case normal, warning, critical
}

struct MenuDisplay: Equatable {
    var state: DisplayState
    var urgency: Urgency
}

enum DisplayState: Equatable {
    case noSession
    case notClockedIn
    case toLunch(timeLeft: TimeInterval)   // counting down to the lunch-leave moment
    case onBreak(timeLeft: TimeInterval)   // counting down to work resuming
    case counting(timeLeft: TimeInterval)  // counting down to leave time
    case overtime(weekly: TimeInterval)

    private static let warningThreshold: TimeInterval = 30 * 60
    private static let criticalThreshold: TimeInterval = 10 * 60

    /// Smart single value with day phases and an overwork urgency level.
    static func computeDisplay(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                               now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> MenuDisplay {
        guard hasSession else { return MenuDisplay(state: .noSession, urgency: .normal) }
        guard let today else { return MenuDisplay(state: .notClockedIn, urgency: .normal) }
        let left = WorkCalculator.timeLeft(clockIn: today.clockIn, now: now, rules: rules)
        if today.clockOut == nil && left > 0 {
            let lunch = WorkCalculator.lunchWindow(on: now, rules: rules, calendar: calendar)
            let leave = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules)
            if leave > lunch.endAt { // lunch phases only apply to a normally-shaped day
                if now < lunch.leaveAt {
                    return MenuDisplay(state: .toLunch(timeLeft: lunch.leaveAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
                if now < lunch.endAt {
                    return MenuDisplay(state: .onBreak(timeLeft: lunch.endAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
            }
            let urgency: Urgency = left <= criticalThreshold ? .critical
                : left <= warningThreshold ? .warning : .normal
            return MenuDisplay(state: .counting(timeLeft: left), urgency: urgency)
        }
        let weekly = WorkCalculator.weeklyOvertime(records: week, now: now, rules: rules)
        // Past leave time with the day still open = overworking right now.
        return MenuDisplay(state: .overtime(weekly: weekly),
                           urgency: today.clockOut == nil ? .critical : .normal)
    }

    /// v1 compatibility wrapper — state only.
    static func compute(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                        now: Date, rules: WorkRules) -> DisplayState {
        computeDisplay(hasSession: hasSession, today: today, week: week,
                       now: now, rules: rules).state
    }

    var menuBarText: String {
        switch self {
        case .noSession: return "—"
        case .notClockedIn: return "--:--"
        case .toLunch(let left): return Formatting.hm(left)
        case .onBreak(let left): return "BREAK " + Formatting.hm(left)
        case .counting(let left): return Formatting.hm(left)
        case .overtime(let weekly): return "OT " + Formatting.signedHM(weekly)
        }
    }

    var iconName: String {
        switch self {
        case .toLunch: return "fork.knife"
        case .onBreak: return "cup.and.saucer"
        default: return "timer"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: ALL pass (44 + 13 new = 57). The v1 `DisplayStateTests`/`AppStateTests` must stay green — they use afternoon/evening times, which the phase logic leaves in `counting`/`overtime` exactly as before. If any v1 test now fails, the phase conditions are wrong — fix the implementation, not the tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: day-phase display states with overwork urgency"
```

---

### Task 3: UI wiring — colored label, icons, dropdown row, README

**Files:**

- Modify: `Sources/FlexTimer/AppState.swift:7,64-69` (publish MenuDisplay)
- Create: `Sources/FlexTimer/MenuBarLabel.swift`
- Modify: `Sources/FlexTimer/FlexTimerApp.swift:14-24` (label)
- Modify: `Sources/FlexTimer/MenuBarView.swift` (Back-at row)
- Modify: `README.md` (display-states table)
- Test: `Tests/FlexTimerTests/AppStateTests.swift` (append)

**Interfaces:**

- Consumes: Task 2's `MenuDisplay`/`Urgency`/`iconName`; Task 1's `lunchWindow`.
- Produces: `AppState.menuDisplay: MenuDisplay` (@Published); `MenuBarLabel(display:text:)` SwiftUI view.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlexTimerTests/AppStateTests.swift` (inside the `AppStateTests` class):

```swift
    func testRecomputePublishesMenuDisplayPhases() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        state.week = [WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)]

        state.recompute(now: d(2026, 7, 9, 10, 0))
        XCTAssertEqual(state.menuDisplay.state, .toLunch(timeLeft: 80 * 60)) // 10:00 → 11:20
        XCTAssertEqual(state.menuText, "1:20")

        state.recompute(now: d(2026, 7, 9, 17, 55))
        XCTAssertEqual(state.menuDisplay.urgency, .critical) // 5 min to 18:00
    }
```

NOTE: this test runs on the user's KST machine where `Calendar.current` == the Seoul test calendar; `recompute` intentionally uses the system calendar.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `AppState` has no member `menuDisplay`.

- [ ] **Step 3: Wire AppState**

In `Sources/FlexTimer/AppState.swift`, add below the `menuText` published property:

```swift
    @Published var menuDisplay = MenuDisplay(state: .notClockedIn, urgency: .normal)
```

and replace the body of `recompute(now:)` with:

```swift
    func recompute(now: Date) {
        let record = todayRecord(now: now)
        let display = DisplayState.computeDisplay(hasSession: hasSession, today: record,
                                                  week: weekIncludingManual(now: now),
                                                  now: now, rules: rules)
        menuDisplay = display
        menuText = display.state.menuBarText
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all pass (58).

- [ ] **Step 5: Create the label view**

`Sources/FlexTimer/MenuBarLabel.swift`:

```swift
import AppKit
import SwiftUI

/// Menu bar label: template-rendered icon+text normally; at warning/critical
/// urgency, pre-renders a colored capsule pill (white icon+text on
/// orange/red) to a non-template NSImage, because the menu bar ignores
/// colors on plain label views.
struct MenuBarLabel: View {
    let display: MenuDisplay
    let text: String

    var body: some View {
        if let pill = display.urgency.pillColor {
            PillLabelImage(icon: display.state.iconName, text: text, background: pill)
        } else {
            HStack(spacing: 3) {
                Image(systemName: display.state.iconName)
                Text(text)
            }
        }
    }
}

extension Urgency {
    var pillColor: Color? {
        switch self {
        case .normal: return nil
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct PillLabelImage: View {
    let icon: String
    let text: String
    let background: Color

    var body: some View {
        Image(nsImage: renderedImage())
    }

    @MainActor private func renderedImage() -> NSImage {
        let content = HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(background))
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
```

- [ ] **Step 6: Use it in the app label**

In `Sources/FlexTimer/FlexTimerApp.swift`, replace the `label:` closure content:

```swift
        } label: {
            MenuBarLabel(display: state.menuDisplay, text: state.menuText)
        }
```

- [ ] **Step 7: Add the Back-at row to the dropdown**

In `Sources/FlexTimer/MenuBarView.swift`, insert at the very top of the outer `VStack` (before the `if let today` block):

```swift
            if case .onBreak = state.menuDisplay.state {
                row("Back at", WorkCalculator.lunchWindow(on: Date(), rules: state.rules).endAt
                    .formatted(date: .omitted, time: .shortened))
            }
```

- [ ] **Step 8: Update README display-states table**

In `README.md`, update the display-states section to describe: morning countdown to lunch-leave (`fork.knife` icon, counts to 11:20 = 11:30 lunch minus the 10-min early-leave allowance), `BREAK H:MM` during 11:20–12:30 (`cup.and.saucer`), the leave countdown and weekly OT as before (`timer`), and the warning pill (orange capsule with white icon+text ≤ 30 min before leave, red ≤ 10 min or while working past leave; back to the plain label after clock-out). Document the three new `defaults write com.perso.flextimer` keys: `lunchStartMinutes -float 690`, `lunchEndMinutes -float 750`, `lunchEarlyLeaveMinutes -float 10`.

- [ ] **Step 9: Full verification**

Run: `swift build && swift test`
Expected: clean build, 58/58 tests pass.

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "feat: phase-aware menu bar label with lunch icons and overwork colors"
```

- [ ] **Step 11: Live smoke test (main session, with the user)**

Rebuild and relaunch the app. Ask the user to confirm: correct phase for the current time of day (icon + countdown), the `Back at 12:30` row during break if applicable, and — by temporarily setting `defaults write com.perso.flextimer dailyWorkHours -float 0.1` or just observing near leave time — that the label becomes an orange/red pill with white content. Reset any temporary defaults afterward (`defaults delete com.perso.flextimer dailyWorkHours`).
