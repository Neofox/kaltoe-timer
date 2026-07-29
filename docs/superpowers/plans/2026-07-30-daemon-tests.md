# KaltoeDaemonTests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the `KaltoeDaemon` coverage gap by adding a test target and one constructor seam, so the Linux daemon's refresh/status logic is verified before typed throws rewrites its catch ladder.

**Architecture:** `HeadlessState` gains an injected `fetchWeek` closure defaulting to the real `FlexClient`, so `refresh()` can be driven without a network. Tests set state up _through_ `refresh()` and read it back _through_ `status(now:)` — no extraction, no relaxed access levels, and the real path is exercised.

**Tech Stack:** Swift 6.3, SwiftPM, XCTest.

Spec: `docs/superpowers/specs/2026-07-29-daemon-tests-design.md`

## This plan is verified transcription

The seam, the test target wiring, and three of the four tests below were written,
compiled, and **run green** under the Swift 6 language mode before this plan
existed, then reverted. Every fixture value (`started` 09:00, `leaveAt` 18:00,
`weekOvertime` 0) and the exact `syncError` string are observed, not derived on
paper.

If you need a change that is not listed here, report it — it means the verified
state and the tree have diverged.

## Global Constraints

- Swift 6 language mode, `swift-tools-version:6.0`, macOS 26 floor. No new dependencies.
- `HeadlessState` is `@MainActor`, so the test class must be `@MainActor` too.
- The test file needs **both** `@testable import KaltoeCore` (for `ParseResult`'s
  memberwise init, which is internal — the struct is public but has no explicit
  `public init`) and `@testable import KaltoeDaemon`.
- The `fetchWeek` parameter must have a **default of `nil`**, so `main.swift:27`'s
  `HeadlessState()` keeps compiling untouched.
- Do not change `status(now:)`, the catch ladder, `StatusLine`, or `ParseResult`.
- Do not give `AppState` the same seam — recorded as a follow-up, out of scope.
- Expected suite totals when done: **140 on macOS** (136 + 4) and **114 on Linux**
  (110 + 4). The daemon target builds on both platforms, so the new tests run on
  both; that is the point of the task.
- Linux test runs require `-e TZ=Asia/Seoul` — the repo documents that 13 tests
  are date-shifted under the container's default UTC.
- **The warning gate is `rm -rf .build && swift build --build-tests`, run once.**
  `swift build` alone does not compile test targets and a warm build re-emits
  nothing; that combination hid four real warnings earlier in this project.
- Commit messages must end with the trailer
  `Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ`.

## File Structure

| File                                               | Responsibility                |
| -------------------------------------------------- | ----------------------------- |
| `Package.swift`                                    | declare the new test target   |
| `Sources/KaltoeDaemon/HeadlessState.swift`         | the injected `fetchWeek` seam |
| `Tests/KaltoeDaemonTests/HeadlessStateTests.swift` | the four tests (new)          |

---

### Task 1: The seam, the target, and the four tests

One task: the test target cannot compile until the seam exists, and the seam has
no purpose without the tests, so there is no intermediate state worth a
reviewer's gate.

**Files:**

- Modify: `Package.swift`
- Modify: `Sources/KaltoeDaemon/HeadlessState.swift`
- Create: `Tests/KaltoeDaemonTests/HeadlessStateTests.swift`

**Interfaces:**

- Produces: `HeadlessState.init(fetchWeek: ((Date, Date) async throws -> ParseResult)? = nil)`.
  Nothing later in this plan consumes it; the follow-up typed-throws work will.

- [ ] **Step 1: Add the test target**

In `Package.swift`, directly after the `KaltoeCoreTests` entry (the line ending
`resources: [.copy("Fixtures")]),`), add:

```swift
    .testTarget(name: "KaltoeDaemonTests", dependencies: ["KaltoeDaemon"], path: "Tests/KaltoeDaemonTests"),
```

This goes in the **unconditional** `targets` array, not inside the
`#if os(macOS)` block — the daemon and its tests build on Linux too.

A test target depending on an executable target with top-level `main.swift` code
works, and the daemon's loop does **not** run during tests. Both were verified.

- [ ] **Step 2: Add the seam**

In `Sources/KaltoeDaemon/HeadlessState.swift`, replace the line

```swift
    private let client = FlexClient()
```

with:

```swift
    /// Injected so tests can drive refresh()'s outcomes without a network.
    /// FlexClient builds its own ephemeral URLSession and exposes no seam of its
    /// own, so this initialiser is the only place a fake can go in.
    private let fetchWeek: (Date, Date) async throws -> ParseResult

    init(fetchWeek: ((Date, Date) async throws -> ParseResult)? = nil) {
        let client = FlexClient()
        self.fetchWeek = fetchWeek ?? { try await client.fetchWeek(from: $0, to: $1) }
    }
```

Then in `refresh()`, change the fetch call from

```swift
            let result = try await client.fetchWeek(from: weekStart, to: max(now, weekEnd))
```

to:

```swift
            let result = try await fetchWeek(weekStart, max(now, weekEnd))
```

Nothing else in the type changes. The `nil` default keeps `main.swift:27`'s
`HeadlessState()` compiling unchanged.

- [ ] **Step 3: Write the tests**

Create `Tests/KaltoeDaemonTests/HeadlessStateTests.swift`:

```swift
import XCTest
@testable import KaltoeCore
@testable import KaltoeDaemon

/// Date in Asia/Seoul, gregorian. Duplicated per this repo's convention:
/// separate test targets don't share top-level helpers.
private func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
}

/// Serves the given outcomes in order, repeating the last one thereafter.
/// A reference box rather than a captured `var` so the escaping closure has no
/// mutable capture.
private final class Script {
    private let outcomes: [Result<ParseResult, Error>]
    private var index = 0

    init(_ outcomes: [Result<ParseResult, Error>]) { self.outcomes = outcomes }

    func next() throws -> ParseResult {
        let outcome = outcomes[min(index, outcomes.count - 1)]
        index += 1
        switch outcome {
        case .success(let page): return page
        case .failure(let error): throw error
        }
    }
}

@MainActor
final class HeadlessStateTests: XCTestCase {
    override func setUp() {
        // status(now:) reads SettingsStore.rules, and todayRecord falls back to
        // SettingsStore.manualStart — isolate both from the developer's domain.
        SettingsStore.defaults = UserDefaults(suiteName: "daemon-tests-\(UUID().uuidString)")!
    }

    /// One open record clocking in 09:00 Wed 2026-07-29. Paired with a `now` later
    /// the same day, so `todayRecord` matches on calendar day and
    /// `weekIncludingManual` keeps it (Monday of that week is 2026-07-27).
    private var page: ParseResult {
        ParseResult(records: [WorkRecord(clockIn: d(2026, 7, 29, 9, 0), clockOut: nil,
                                         flexWorkedNet: nil)],
                    dayOffDates: [], timeOff: [:])
    }

    private func state(_ outcomes: [Result<ParseResult, Error>]) -> HeadlessState {
        let script = Script(outcomes)
        return HeadlessState { _, _ in try script.next() }
    }

    func testSuccessfulRefreshPopulatesTheStatusLine() async {
        let state = state([.success(page)])
        await state.refresh()

        let line = state.status(now: d(2026, 7, 29, 15, 0))
        XCTAssertTrue(line.hasSession)
        XCTAssertNil(line.syncError)
        XCTAssertNotNil(line.lastSync)   // set from the real clock, so only non-nil is assertable
        XCTAssertEqual(line.started, d(2026, 7, 29, 9, 0))
        XCTAssertEqual(line.leaveAt, d(2026, 7, 29, 18, 0))  // 09:00 + 8h target + 1h break
        XCTAssertEqual(line.weekOvertime, 0)                 // 15:00 is before leave time
    }

    /// The three optional NDJSON fields are gated on `hasSession`, and the tray's
    /// menu rows read them. Refreshing successfully *first* is what makes this
    /// discriminating: week data survives, so nil can only come from the gate.
    func testSessionExpiredGatesEveryOptionalFieldDespiteLiveWeekData() async {
        let state = state([.success(page), .failure(FlexClient.FlexError.sessionExpired)])
        await state.refresh()
        await state.refresh()

        XCTAssertFalse(state.hasSession)
        XCTAssertEqual(state.weekData.records.count, 1, "week data must survive, or nil proves nothing")

        let line = state.status(now: d(2026, 7, 29, 15, 0))
        XCTAssertNil(line.started)
        XCTAssertNil(line.leaveAt)
        XCTAssertNil(line.weekOvertime)
    }

    /// The `where` clause matches two cases; testing one would leave half unpinned.
    func testNoSessionGatesEveryOptionalFieldToo() async {
        let state = state([.success(page), .failure(FlexClient.FlexError.noSession)])
        await state.refresh()
        await state.refresh()

        XCTAssertFalse(state.hasSession)
        XCTAssertEqual(state.weekData.records.count, 1)

        let line = state.status(now: d(2026, 7, 29, 15, 0))
        XCTAssertNil(line.started)
        XCTAssertNil(line.leaveAt)
        XCTAssertNil(line.weekOvertime)
    }

    /// "Sync failure keeps last data" — the type's doc comment, previously unverified.
    func testNonSessionErrorKeepsLastKnownData() async {
        let state = state([.success(page), .failure(URLError(.timedOut))])
        await state.refresh()
        let firstSync = state.lastSync
        await state.refresh()

        XCTAssertEqual(state.syncError, "Flex sync failed — showing last known data")
        XCTAssertEqual(state.lastSync, firstSync, "a failed sync must not move lastSync")
        XCTAssertEqual(state.weekData.records.count, 1)
        XCTAssertTrue(state.hasSession, "a transport error is not a session error")
    }
}
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter HeadlessStateTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Verify the tests discriminate**

A green test that cannot fail proves nothing, and the whole point of this task is
to guard code that is about to be edited. Prove the two most important tests bite:

1. Temporarily delete `hasSession = false` from the `FlexError` catch arm in
   `HeadlessState.swift`. Expect **both** gating tests
   (`testSessionExpiredGates…` and `testNoSessionGates…`) to fail. Restore.
2. Temporarily move `lastSync = now` above the `let result = try await …` line, so
   a failed sync updates it. Expect `testNonSessionErrorKeepsLastKnownData` to
   fail on the `lastSync` assertion. Restore.

Report what you observed for each, and confirm `git diff` is empty afterwards.

- [ ] **Step 6: Full suite and the cold warning gate**

Run: `swift test`
Expected: **140 tests, 0 failures.**

Run once, cold: `rm -rf .build && swift build --build-tests 2>&1 | grep -c "warning:"`
Expected: **0**. Do not repeat it — a second run is warm and reports 0 regardless.

- [ ] **Step 7: Verify Linux**

`Package.swift` changed and the daemon is the Linux product, so both Linux checks
are required.

```bash
./scripts/build-linux.sh
```

Expected: succeeds, with only the two pre-existing warnings
(`CookieVault.swift:110` unused `createFile` result, and `libFoundationEssentials`
`mktemp` linker noise).

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e TZ=Asia/Seoul swift:6.1-noble swift test --scratch-path .build-linux
```

Expected: **114 tests, 0 failures.**

`-e TZ=Asia/Seoul` is required, not optional.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/KaltoeDaemon/HeadlessState.swift Tests/KaltoeDaemonTests/
git commit -m "test: cover HeadlessState's refresh outcomes and status gating

Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ"
```
