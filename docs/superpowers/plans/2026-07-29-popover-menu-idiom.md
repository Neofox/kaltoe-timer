# Popover Menu Idiom & Unlock Re-sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the menu bar popover to read as a native macOS menu, re-sync when the screen unlocks so the morning no longer starts with a manual refresh, and stop recomputing the weekly overtime total twice per second.

**Architecture:** `computeDisplay` stops deriving the weekly total and takes it as a parameter, which removes its `week` argument entirely and lets both callers share one computation. A new `MenuRow` primitive provides full-bleed hover rows so `MenuBarView` becomes composition. `AppState` gains a `com.apple.screenIsUnlocked` observer with a bounded retry whose policy is a pure, testable predicate.

**Tech Stack:** Swift 5.9, SwiftUI (`MenuBarExtra`), AppKit, DistributedNotificationCenter, XCTest, SwiftPM.

Spec: `docs/superpowers/specs/2026-07-29-popover-menu-idiom-design.md`

## Global Constraints

- Swift tools version 5.9; deployment target macOS 13. No new dependencies.
- `KaltoeCore` must not import AppKit, SwiftUI, or UserNotifications — it also
  builds for Linux. All view code stays in `Sources/FlexTimer`.
- Exact copy, verbatim:
  - Refresh row title: `Flex re-sync`
  - Sign-in row title: `Sign in to Flex…` (note the ellipsis character, not three dots)
  - Preference row title: `Stay readable when unfocused`
  - Quit row title: `Quit`
  - Manual-entry caption: `Or set it manually`
  - Tooltip on the preference row: `Renders the icon and time at full contrast so they stay legible on the menu bar of a display that doesn't have focus.`
- Popover width is exactly `280`. This is driven by the preference row's label
  (28 characters ≈ 179pt at the 13pt system font), not by taste — at 260 it clips.
- Highlight is solid `Color.accentColor` with foreground knocked out to white.
  The softer alternative (`Color.accentColor.opacity(0.15)`, unchanged
  foreground) is a deliberate one-line fallback if the solid fill reads heavy;
  do not substitute it unsolicited.
- SF Symbols, exact names: `arrow.clockwise`, `person.crop.circle`,
  `circle.lefthalf.filled`, `power`, `exclamationmark.triangle`.
- The poll interval stays at 600 seconds. Do not change it.
- `AppState` has no `deinit` and `wakeObserver` is never removed. This is
  deliberate — the object lives for the process lifetime. Do not add a `deinit`.
- Run tests from the repo root with `swift test`. Current baseline: **131 tests**.
- Markdown files must be patched via Bash, never Edit/Write — a prettier
  `PostToolUse` hook reflows them. No markdown changes are expected in this plan.

## File Structure

| File                                       | Responsibility                                                     | Task |
| ------------------------------------------ | ------------------------------------------------------------------ | ---- |
| `Sources/KaltoeCore/DisplayState.swift`    | Map today's record + the week's total to a display and urgency     | 1    |
| `Sources/FlexTimer/AppState.swift`         | Wiring: one weekly computation per tick; unlock observer and retry | 1, 2 |
| `Sources/KaltoeDaemon/HeadlessState.swift` | Linux status line — shares the same single computation             | 1    |
| `Sources/FlexTimer/MenuRow.swift`          | Full-bleed menu row primitive (new)                                | 3    |
| `Sources/FlexTimer/MenuBarView.swift`      | Popover composition and state-dependent ordering                   | 3    |

---

### Task 1: `computeDisplay` takes the weekly total

**Files:**

- Modify: `Sources/KaltoeCore/DisplayState.swift` (signature; drop the internal computation; delete the `compute` wrapper)
- Modify: `Sources/FlexTimer/AppState.swift` (`recompute`)
- Modify: `Sources/KaltoeDaemon/HeadlessState.swift` (`status`)
- Test: `Tests/KaltoeCoreTests/FormattingTests.swift` (migrate 10 call sites)

**Interfaces:**

- Produces: `DisplayState.computeDisplay(hasSession:today:weeklyOvertime:timeOff:now:rules:calendar:) -> MenuDisplay` — **no `week` parameter**. Task 3 does not call it, but `AppState` and `HeadlessState` do.
- Removes: `DisplayState.compute(hasSession:today:week:now:rules:)`.

This task is a pure refactor: no behaviour changes and no test expectations move.
The suite staying at 131 green is the proof.

- [ ] **Step 1: Change the signature and use the parameter**

In `Sources/KaltoeCore/DisplayState.swift`, replace the `computeDisplay`
declaration and its doc comment with:

```swift
    /// Smart single value with day phases and an overwork urgency level.
    ///
    /// `weeklyOvertime` is supplied by the caller rather than derived here.
    /// Both callers already compute it for their own purposes, and `recompute`
    /// runs every second — deriving it again inside this function was pure
    /// waste. Taking it as a parameter also removes the need for `week`, which
    /// fed nothing else.
    public static func computeDisplay(hasSession: Bool, today: WorkRecord?,
                               weeklyOvertime: TimeInterval,
                               timeOff: [Date: TimeInterval] = [:],
                               now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> MenuDisplay {
```

Then delete these two lines from the overtime branch:

```swift
        // Weekly total is computed for the cap check only — the menu bar shows today.
        let weekly = WorkCalculator.weeklyOvertime(records: week, timeOff: timeOff,
                                                   now: now, rules: rules)
```

and change the cap check from `weeklyOvertime: weekly` to
`weeklyOvertime: weeklyOvertime`:

```swift
        if WorkCalculator.hasReachedWeeklyCap(weeklyOvertime: weeklyOvertime, rules: rules) {
```

- [ ] **Step 2: Delete the v1 compatibility wrapper**

Delete the whole `compute` function and its doc comment from
`Sources/KaltoeCore/DisplayState.swift`:

```swift
    /// v1 compatibility wrapper — state only.
    public static func compute(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                        now: Date, rules: WorkRules) -> DisplayState {
        computeDisplay(hasSession: hasSession, today: today, week: week,
                       now: now, rules: rules).state
    }
```

It has no production callers — only three assertions in `FormattingTests`,
migrated in Step 5 — and it takes the `week` parameter being removed.

- [ ] **Step 3: Share one computation in `AppState.recompute`**

In `Sources/FlexTimer/AppState.swift`, replace the body of `recompute(now:)` with:

```swift
    func recompute(now: Date) {
        let record = todayRecord(now: now)
        hookRunner?.evaluate(today: record, now: now)
        // Derived once and shared. This runs every second, and the display and
        // the notifier need the same figure — computing it twice was thousands
        // of redundant passes an hour.
        let weekly = WorkCalculator.weeklyOvertime(records: weekIncludingManual(now: now),
                                                   timeOff: timeOff, now: now, rules: rules)
        let display = DisplayState.computeDisplay(hasSession: hasSession, today: record,
                                                  weeklyOvertime: weekly,
                                                  timeOff: timeOff,
                                                  now: now, rules: rules)
        menuDisplay = display
        menuText = display.state.menuBarText
        limitNotifier?.evaluate(weeklyOvertime: weekly,
                                clockedIn: record?.clockOut == nil && record != nil,
                                now: now, rules: rules)
    }
```

- [ ] **Step 4: Share one computation in `HeadlessState.status`**

In `Sources/KaltoeDaemon/HeadlessState.swift`, replace the body of `status(now:)` with:

```swift
    func status(now: Date) -> StatusLine {
        let today = weekData.todayRecord(now: now)
        let week = weekData.weekIncludingManual(now: now)
        let rules = SettingsStore.rules
        // One computation feeds both the display's cap check and the status
        // line's own field; this used to be derived twice.
        let weekly = WorkCalculator.weeklyOvertime(records: week,
                                                   timeOff: weekData.timeOff,
                                                   now: now, rules: rules)
        let display = DisplayState.computeDisplay(hasSession: hasSession,
                                                  today: today,
                                                  weeklyOvertime: weekly,
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
                          leaveAt: leaveAt, weekOvertime: hasSession ? weekly : nil)
    }
```

Note `weekOvertime` keeps its `hasSession ? … : nil` behaviour — the field is
still omitted from the JSON when signed out.

- [ ] **Step 5: Migrate the test call sites**

In `Tests/KaltoeCoreTests/FormattingTests.swift`, ten call sites change. For
each, replace the `week:` argument with a `weeklyOvertime:` argument carrying
the value that `week` would have summed to.

**The three `compute` calls** (lines 37, 43, 50) become `computeDisplay(...).state`.
All three return before the weekly figure is read — `hasSession: false` and
`today: nil` exit early, and the third lands in the counting branch — so pass `0`:

```swift
        XCTAssertEqual(DisplayState.computeDisplay(hasSession: false, today: nil,
                                                   weeklyOvertime: 0,
                                                   now: d(2026, 7, 6, 9, 0), rules: rules).state,
                       .noSession)
```

```swift
        XCTAssertEqual(DisplayState.computeDisplay(hasSession: true, today: nil,
                                                   weeklyOvertime: 0,
                                                   now: d(2026, 7, 6, 8, 0), rules: rules).state,
                       .notClockedIn)
```

```swift
        let s = DisplayState.computeDisplay(hasSession: true, today: today,
                                            weeklyOvertime: 0,
                                            now: d(2026, 7, 6, 15, 25), rules: rules).state
```

**The seven `computeDisplay` calls** (lines 61, 76, 97, 166, 182, 199, 207):

| Line | Test                                                  | `week:` was   | Pass `weeklyOvertime:` | Why                                                                 |
| ---- | ----------------------------------------------------- | ------------- | ---------------------- | ------------------------------------------------------------------- |
| 61   | `testOvertimePastLeaveTimeShowsTodayAndWarns`         | `[today]`     | `3600`                 | today's +1h is the week's whole total                               |
| 76   | `testOvertimeClockedOutEarlyShowsNegativeAndIsNormal` | `[today]`     | `0`                    | today is −1h, and the weekly sum floors each day at 0               |
| 97   | `display(...)` helper                                   | `[today]`     | `0`                    | every caller lands in a lunch or counting phase, where it is unread |
| 166  | `testPastCutoffWhileClockedInIsCritical`              | `[today]`     | `4.5 * 3600`           | today's +4h30 is the week's whole total                             |
| 182  | `testPastCutoffWhileClockedOutIsNormal`               | `[today]`     | `3600`                 | today's +1h is the week's whole total                               |
| 199  | `testWeeklyCapIsCriticalEvenWhenClockedOut`           | four 12h days | `12 * 3600`            | the cap boundary this test exists to pin                            |
| 207  | `testNoSessionAndNotClockedInAreNormalWithTimerIcon`  | `[]`          | `0`                    | returns before the figure is read                                   |

Line 199 is worth a comment in the test: it previously derived 12h from four
constructed records, and now states it. That is a **gain** in focus, not a loss
— the gross-sum arithmetic is already pinned by `WorkCalculatorTests`, and this
test's subject is what `computeDisplay` does when handed a total at the cap.

Line 97 is not a test — it is inside a helper named `display(...)`. Add a
defaulted parameter so its callers stay unchanged:

```swift
    func display(_ clockIn: Date, _ now: Date, clockOut: Date? = nil,
                 r: WorkRules? = nil, weeklyOvertime: TimeInterval = 0) -> MenuDisplay {
        let today = WorkRecord(clockIn: clockIn, clockOut: clockOut, flexWorkedNet: nil)
        return DisplayState.computeDisplay(hasSession: true, today: today,
                                           weeklyOvertime: weeklyOvertime,
                                           now: now, rules: r ?? rules, calendar: seoul)
    }
```

It passes no `timeOff:` argument today — leave it that way. Before moving on,
check whether any `display(...)` caller lands in the overtime branch and asserts
`.critical` from the cap; if one does, give that call an explicit
`weeklyOvertime:` instead of relying on the `0` default. The phase-boundary
tests it was written for all land in lunch or counting phases, where the figure
is never read.

Match each call's existing argument order and trailing arguments (`timeOff:`,
`calendar:`) — only the `week:` argument is being swapped.

- [ ] **Step 6: Build and run the full suite**

Run: `swift build && swift test`
Expected: PASS, **131 tests**, output pristine. The count is unchanged because
nothing was added or removed — the three `compute` tests migrated rather than
being deleted. Any expectation that had to move means the refactor changed
behaviour; stop and report it.

- [ ] **Step 7: Commit**

```bash
git add Sources/KaltoeCore/DisplayState.swift Sources/FlexTimer/AppState.swift \
        Sources/KaltoeDaemon/HeadlessState.swift Tests/KaltoeCoreTests/FormattingTests.swift
git commit -m "refactor: computeDisplay takes the weekly total instead of deriving it

Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ"
```

---

### Task 2: Re-sync when the screen unlocks

**Files:**

- Modify: `Sources/FlexTimer/AppState.swift` (property, predicate, `resyncAfterUnlock`, observer in `start()`)
- Test: `Tests/FlexTimerTests/AppStateTests.swift` (append 4 tests)

**Interfaces:**

- Consumes: `AppState.refresh()`, `AppState.today`, `AppState.hasSession`.
- Produces: `AppState.shouldRetryUnlockResync(attempt:maxAttempts:hasSession:hasTodayRecord:) -> Bool` and `AppState.resyncAfterUnlock(maxAttempts:delay:) async`.

`attempt` is **0-based**: the predicate is consulted after attempt `n` has
already run, and answers whether an attempt `n + 1` should follow.

- [ ] **Step 1: Write the failing tests**

Append to the existing `@MainActor final class AppStateTests` in
`Tests/FlexTimerTests/AppStateTests.swift`:

```swift
    func testUnlockResyncStopsOnceARecordArrives() {
        XCTAssertFalse(AppState.shouldRetryUnlockResync(attempt: 0, maxAttempts: 3,
                                                        hasSession: true, hasTodayRecord: true))
    }

    /// Retrying a dead session just hammers it — the sign-in notification is
    /// the recovery path, not another fetch.
    func testUnlockResyncStopsImmediatelyWhenSignedOut() {
        XCTAssertFalse(AppState.shouldRetryUnlockResync(attempt: 0, maxAttempts: 3,
                                                        hasSession: false, hasTodayRecord: false))
    }

    func testUnlockResyncStopsAtTheCeiling() {
        XCTAssertFalse(AppState.shouldRetryUnlockResync(attempt: 2, maxAttempts: 3,
                                                        hasSession: true, hasTodayRecord: false))
    }

    func testUnlockResyncContinuesWhileWaitingForARecord() {
        XCTAssertTrue(AppState.shouldRetryUnlockResync(attempt: 0, maxAttempts: 3,
                                                       hasSession: true, hasTodayRecord: false))
        XCTAssertTrue(AppState.shouldRetryUnlockResync(attempt: 1, maxAttempts: 3,
                                                       hasSession: true, hasTodayRecord: false))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter testUnlockResync`
Expected: FAIL — compile error, `type 'AppState' has no member 'shouldRetryUnlockResync'`.

- [ ] **Step 3: Write the predicate**

In `Sources/FlexTimer/AppState.swift`, add above `recompute(now:)`:

```swift
    /// Whether an unlock re-sync should try again. `attempt` is 0-based and
    /// names the attempt that just finished. Stops as soon as a record arrives,
    /// stops immediately when signed out — retrying a dead session only hammers
    /// it — and stops at the ceiling.
    static func shouldRetryUnlockResync(attempt: Int, maxAttempts: Int,
                                        hasSession: Bool, hasTodayRecord: Bool) -> Bool {
        guard hasSession, !hasTodayRecord else { return false }
        return attempt + 1 < maxAttempts
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter testUnlockResync`
Expected: PASS, 4 tests.

- [ ] **Step 5: Add the retry loop**

In `Sources/FlexTimer/AppState.swift`, add below `refresh()`:

```swift
    /// Re-sync after the screen unlocks, retrying briefly when Flex still has
    /// no record: the user typically clocks in moments before unlocking, and
    /// the API lags that by seconds.
    func resyncAfterUnlock(maxAttempts: Int = 3, delay: TimeInterval = 20) async {
        for attempt in 0..<maxAttempts {
            await refresh()
            guard Self.shouldRetryUnlockResync(attempt: attempt, maxAttempts: maxAttempts,
                                               hasSession: hasSession,
                                               hasTodayRecord: today != nil) else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
```

- [ ] **Step 6: Observe the unlock notification**

In `Sources/FlexTimer/AppState.swift`, add beside `wakeObserver` (around line 38):

```swift
    /// Stored to mirror `wakeObserver` and, like it, never removed: AppState
    /// lives for the process lifetime, so there is no deinit for removal to
    /// run in.
    private var unlockObserver: NSObjectProtocol?
```

and in `start()`, directly after the `wakeObserver` assignment:

```swift
        // didWakeNotification only fires when the Mac wakes from sleep. A Mac
        // that was merely locked never posts it, which is the case that had the
        // user clicking refresh every morning.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.resyncAfterUnlock() }
        }
```

- [ ] **Step 7: Build and run the full suite**

Run: `swift build && swift test`
Expected: PASS, **135 tests** (131 + 4), output pristine. Existing `AppStateTests`
must be unaffected — `resyncAfterUnlock` is only reachable from the observer,
which `start()` installs and unit tests never call.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlexTimer/AppState.swift Tests/FlexTimerTests/AppStateTests.swift
git commit -m "feat: re-sync on screen unlock, not only on wake from sleep

Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ"
```

---

### Task 3: The popover as a menu

**Files:**

- Create: `Sources/FlexTimer/MenuRow.swift`
- Modify: `Sources/FlexTimer/MenuBarView.swift` (replace contents)

**Interfaces:**

- Consumes: `AppState.today`, `.hasSession`, `.menuDisplay`, `.timeOff`, `.rules`, `.syncError`, `.lastSync`, `.highContrastOnInactiveDisplays`, `.weekIncludingManual(now:)`, `.refresh()`, `.signIn()`, `.recompute(now:)`; `WorkCalculator`, `Formatting`, `SettingsStore` from `KaltoeCore`.
- Produces: `MenuRow`, used only by `MenuBarView`.

No tests. This is pure presentation with no extractable logic, and the
properties that matter — does the highlight look right, does the label fit —
are only observable by eye. Same judgement as `MenuBarLabel`. The suite staying
at 135 is the proof that nothing else broke.

- [ ] **Step 1: Create `MenuRow`**

Create `Sources/FlexTimer/MenuRow.swift`:

```swift
import SwiftUI

/// A full-bleed menu-style row: icon column, title, optional trailing accessory,
/// solid accent highlight on hover.
///
/// The horizontal padding lives here rather than on the parent stack because the
/// highlight has to reach the popover's edges while the text stays inset — one
/// shared padding cannot serve both.
struct MenuRow<Trailing: View>: View {
    private let icon: String
    private let title: String
    private let action: () -> Void
    private let trailing: Trailing

    @State private var hovering = false

    init(icon: String, title: String, action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16)
            Text(title)
            Spacer(minLength: 8)
            trailing
        }
        .foregroundStyle(hovering ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

extension MenuRow where Trailing == EmptyView {
    init(icon: String, title: String, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, action: action, trailing: { EmptyView() })
    }
}
```

The explicit initialisers are deliberate: a `@ViewBuilder`-annotated stored
property does not get builder semantics through the memberwise initialiser.

- [ ] **Step 2: Replace `MenuBarView`**

Replace the entire contents of `Sources/FlexTimer/MenuBarView.swift` with:

```swift
import SwiftUI
import KaltoeCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @State private var manualTime = Date()

    /// With no record for today, the primary action moves up next to the status
    /// message — waiting for a clock-in is exactly when you want it, and the
    /// manual-entry field is only a fallback for when Flex is unreachable.
    private var hasRecord: Bool { state.today != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            information

            if !hasRecord {
                separator
                primaryAction
                separator
                manualEntry
            }

            separator
            weekSummary

            separator
            if hasRecord { primaryAction }
            highContrastRow
            separator
            MenuRow(icon: "power", title: "Quit") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }

    private var separator: some View {
        Divider().padding(.vertical, 4)
    }

    @ViewBuilder private var information: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .onBreak = state.menuDisplay.state {
                row("Back at", WorkCalculator.lunchWindow(on: Date(), rules: state.rules).endAt
                    .formatted(date: .omitted, time: .shortened))
            }
            if let today = state.today, state.hasSession {
                let off = WorkCalculator.timeOff(on: today.clockIn, in: state.timeOff)
                row("Started", today.clockIn.formatted(date: .omitted, time: .shortened))
                row("Leave at", WorkCalculator.leaveTime(clockIn: today.clockIn, rules: state.rules,
                                                         timeOff: off)
                    .formatted(date: .omitted, time: .shortened))
                row("Time left", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules, timeOff: off)))
            } else if state.hasSession {
                Text("Not clocked in yet").foregroundStyle(.secondary)
            } else {
                Text("Session expired").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var primaryAction: some View {
        if state.hasSession {
            MenuRow(icon: "arrow.clockwise", title: "Flex re-sync") {
                Task { await state.refresh() }
            }
        } else {
            MenuRow(icon: "person.crop.circle", title: "Sign in to Flex…") { state.signIn() }
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or set it manually").font(.caption).foregroundStyle(.secondary)
            HStack {
                DatePicker("Started at", selection: $manualTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .controlSize(.small)
                Button("Set") {
                    SettingsStore.setManualStart(manualTime, on: Date())
                    state.recompute(now: Date())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
    }

    private var weekSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            let weekOT = WorkCalculator.weeklyOvertime(
                records: state.weekIncludingManual(now: Date()),
                timeOff: state.timeOff, now: Date(), rules: state.rules)
            row("Week OT", "\(Formatting.hm(weekOT)) / \(Formatting.hm(state.rules.weeklyOvertimeCap))")
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

    private var highContrastRow: some View {
        MenuRow(icon: "circle.lefthalf.filled", title: "Stay readable when unfocused") {
            state.highContrastOnInactiveDisplays.toggle()
        } trailing: {
            Toggle("", isOn: $state.highContrastOnInactiveDisplays)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // The row owns the tap. Without this, clicking the switch itself
                // fires both the switch and the row action, which cancel out.
                .allowsHitTesting(false)
        }
        .help("Renders the icon and time at full contrast so they stay legible on the menu bar of a display that doesn't have focus.")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
```

Two copy changes beyond the constrained strings: the signed-out message drops
to `Session expired` (it previously read "Session expired — sign in below", and
the sign-in row now sits directly beneath it), and `syncError` becomes a `Label`
so it carries a warning symbol.

- [ ] **Step 3: Build and run the full suite**

Run: `swift build && swift test`
Expected: build succeeds, **135 tests** pass, no new warnings. If
`.allowsHitTesting(false)`, the `@ViewBuilder` initialisers, or
`.onTapGesture(perform:)` fail to compile, report it rather than redesigning —
the interaction model matters more than any one modifier.

- [ ] **Step 4: Build the bundle**

Run: `./scripts/bundle.sh`
Expected: succeeds. **Do not launch it** — the user is running 칼퇴타이머, and a
second instance from the build directory would register a Login Item pointing
at a build path. The human does the visual check.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/MenuRow.swift Sources/FlexTimer/MenuBarView.swift
git commit -m "feat: popover reads as a native menu, primary action follows state

Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ"
```

---

## Human verification

Not runnable by an agent. After `./scripts/bundle.sh`:

1. Hovering Flex re-sync, the preference row, and Quit each highlights edge to
   edge in the accent colour with white text; the information rows never do.
2. "Stay readable when unfocused" sits on one line beside its icon and switch.
3. Clicking anywhere on the preference row flips the switch — **and clicking
   directly on the switch flips it exactly once**, not zero times.
4. With no record for today, Flex re-sync appears above the manual-entry field
   and the action zone holds only the preference row and Quit.
5. Lock the screen without letting the Mac sleep, clock in via the Flex web UI,
   then unlock — the record appears without touching Flex re-sync. This is the
   check that proves the morning fix.
