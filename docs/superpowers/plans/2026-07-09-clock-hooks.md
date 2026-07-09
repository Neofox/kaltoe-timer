# 출근/퇴근 Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run user-provided scripts (`on-clock-in`, `on-clock-out`) from `~/Library/Application Support/칼퇴타이머/hooks/` when the app detects 출근/퇴근, once per event per day.

**Architecture:** A new `HookRunner` class watches today's `WorkRecord` on every `AppState.recompute` tick, fires each event at most once per day (dedupe persisted in UserDefaults), and launches scripts detached via `Process`. The executor is an injected closure so all logic is unit-testable without spawning processes. The runner is attached in `AppState.start()` only, so unit tests (which call `recompute` directly, never `start()`) can never launch real scripts.

**Tech Stack:** Swift Package Manager, XCTest, Foundation `Process`/`UserDefaults`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-09-clock-hooks-design.md`

## Global Constraints

- Hooks directory is exactly `~/Library/Application Support/칼퇴타이머/hooks/` with scripts named `on-clock-in` and `on-clock-out`.
- Env vars are exactly `KALTOE_EVENT` (`clock-in`/`clock-out`), `KALTOE_CLOCK_IN` (ISO8601), `KALTOE_CLOCK_OUT` (ISO8601, clock-out only), merged on top of the app's environment.
- Dedupe keys are exactly `hookFired-clockIn-yyyy-MM-dd` / `hookFired-clockOut-yyyy-MM-dd`, stored in `SettingsStore.defaults` by default.
- Fire-and-forget: never wait on a script, never read its output. Missing or non-executable script → silently skipped.
- No settings, no UI, no new dependencies. If the hooks directory doesn't exist, the app behaves exactly as before.
- Test style: per-test `UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!`, the shared `d(y,mo,da,h,mi)` date helper from `WorkCalculatorTests.swift`.
- Run tests with `swift test` (full suite must pass at every commit).

---

### Task 1: HookRunner transition logic (TDD, spy executor)

**Files:**

- Create: `Sources/FlexTimer/HookRunner.swift`
- Test: `Tests/FlexTimerTests/HookRunnerTests.swift`

**Interfaces:**

- Consumes: `WorkRecord` (`Sources/FlexTimer/WorkCalculator.swift:12` — `clockIn: Date`, `clockOut: Date?`, `flexWorkedNet: TimeInterval?`), `SettingsStore.defaults`.
- Produces: `final class HookRunner` with:
    - `init(defaults: UserDefaults = SettingsStore.defaults, execute: @escaping (URL, [String: String]) -> Void = HookRunner.launchDetached)`
    - `func evaluate(today: WorkRecord?, now: Date)`
    - `static var hooksDirectory: URL`
    - `static func launchDetached(_ script: URL, _ env: [String: String])` — **stub only in this task** (empty body); real implementation is Task 2.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlexTimerTests/HookRunnerTests.swift`:

```swift
import XCTest
@testable import FlexTimer

final class HookRunnerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var fired: [(script: URL, env: [String: String])] = []

    override func setUp() {
        defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        fired = []
    }

    private func makeRunner() -> HookRunner {
        HookRunner(defaults: defaults) { [self] url, env in fired.append((url, env)) }
    }

    private let openRecord = WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)
    private let closedRecord = WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: d(2026, 7, 9, 19, 0), flexWorkedNet: nil)
    private let morning = d(2026, 7, 9, 9, 5)
    private let evening = d(2026, 7, 9, 19, 5)

    func testNoRecordNoFire() {
        makeRunner().evaluate(today: nil, now: morning)
        XCTAssertTrue(fired.isEmpty)
    }

    func testClockInFiresOnceWithEnv() {
        let runner = makeRunner()
        runner.evaluate(today: openRecord, now: morning)
        XCTAssertEqual(fired.count, 1)
        XCTAssertTrue(fired[0].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-in"))
        XCTAssertEqual(fired[0].env["KALTOE_EVENT"], "clock-in")
        XCTAssertEqual(ISO8601DateFormatter().date(from: fired[0].env["KALTOE_CLOCK_IN"] ?? ""),
                       openRecord.clockIn)
        XCTAssertNil(fired[0].env["KALTOE_CLOCK_OUT"])

        runner.evaluate(today: openRecord, now: morning) // second tick: deduped
        XCTAssertEqual(fired.count, 1)
    }

    func testClockOutFiresOnceAfterClockOutAppears() {
        let runner = makeRunner()
        runner.evaluate(today: openRecord, now: morning)   // clock-in fires
        runner.evaluate(today: closedRecord, now: evening) // clock-out fires
        XCTAssertEqual(fired.count, 2)
        XCTAssertTrue(fired[1].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-out"))
        XCTAssertEqual(fired[1].env["KALTOE_EVENT"], "clock-out")
        XCTAssertEqual(ISO8601DateFormatter().date(from: fired[1].env["KALTOE_CLOCK_IN"] ?? ""),
                       closedRecord.clockIn)
        XCTAssertEqual(ISO8601DateFormatter().date(from: fired[1].env["KALTOE_CLOCK_OUT"] ?? ""),
                       closedRecord.clockOut)

        runner.evaluate(today: closedRecord, now: evening) // deduped
        XCTAssertEqual(fired.count, 2)
    }

    func testLateDetectionFiresBothOnce() {
        // App launched after both events already happened: fire each exactly once.
        makeRunner().evaluate(today: closedRecord, now: evening)
        XCTAssertEqual(fired.map { $0.env["KALTOE_EVENT"] }, ["clock-in", "clock-out"])
    }

    func testDedupePersistsAcrossInstances() {
        makeRunner().evaluate(today: openRecord, now: morning)
        makeRunner().evaluate(today: openRecord, now: morning) // fresh runner, same defaults
        XCTAssertEqual(fired.count, 1)
    }

    func testStaleKeysRemovedWhenNewDayFires() {
        defaults.set(true, forKey: "hookFired-clockIn-2026-07-08")
        defaults.set(true, forKey: "hookFired-clockOut-2026-07-08")
        makeRunner().evaluate(today: openRecord, now: morning)
        XCTAssertNil(defaults.object(forKey: "hookFired-clockIn-2026-07-08"))
        XCTAssertNil(defaults.object(forKey: "hookFired-clockOut-2026-07-08"))
        XCTAssertNotNil(defaults.object(forKey: "hookFired-clockIn-2026-07-09"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --filter HookRunnerTests`
Expected: build error — `cannot find 'HookRunner' in scope`

- [ ] **Step 3: Implement HookRunner**

Create `Sources/FlexTimer/HookRunner.swift`:

```swift
import Foundation

/// Runs user hook scripts on detected 출근/퇴근, at most once per event per day.
///
/// Scripts are optional executables in `~/Library/Application Support/칼퇴타이머/hooks/`
/// (`on-clock-in`, `on-clock-out`). Dedupe state persists in UserDefaults as
/// `hookFired-<event>-yyyy-MM-dd`, so app restarts never re-fire, but an app
/// launched after the real event still fires once (late detection).
final class HookRunner {
    static var hooksDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("칼퇴타이머/hooks", isDirectory: true)
    }

    private let defaults: UserDefaults
    private let execute: (URL, [String: String]) -> Void
    private let iso = ISO8601DateFormatter()

    init(defaults: UserDefaults = SettingsStore.defaults,
         execute: @escaping (URL, [String: String]) -> Void = HookRunner.launchDetached) {
        self.defaults = defaults
        self.execute = execute
    }

    func evaluate(today: WorkRecord?, now: Date) {
        guard let record = today else { return }
        let day = Self.dayString(now)
        if markFiredIfNeeded("clockIn", day: day) {
            execute(Self.hooksDirectory.appendingPathComponent("on-clock-in"),
                    ["KALTOE_EVENT": "clock-in",
                     "KALTOE_CLOCK_IN": iso.string(from: record.clockIn)])
        }
        if let clockOut = record.clockOut, markFiredIfNeeded("clockOut", day: day) {
            execute(Self.hooksDirectory.appendingPathComponent("on-clock-out"),
                    ["KALTOE_EVENT": "clock-out",
                     "KALTOE_CLOCK_IN": iso.string(from: record.clockIn),
                     "KALTOE_CLOCK_OUT": iso.string(from: clockOut)])
        }
    }

    /// True if the event had not fired today; marks it fired and drops stale keys.
    private func markFiredIfNeeded(_ event: String, day: String) -> Bool {
        let key = "hookFired-\(event)-\(day)"
        guard defaults.object(forKey: key) == nil else { return false }
        for stale in defaults.dictionaryRepresentation().keys
        where stale.hasPrefix("hookFired-") && !stale.hasSuffix(day) {
            defaults.removeObject(forKey: stale)
        }
        defaults.set(true, forKey: key)
        return true
    }

    private static func dayString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    /// Default executor. Real implementation lands with the AppState wiring task.
    static func launchDetached(_ script: URL, _ env: [String: String]) {
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HookRunnerTests`
Expected: 7 tests pass

Run: `swift test`
Expected: full suite passes

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/HookRunner.swift Tests/FlexTimerTests/HookRunnerTests.swift
git commit -m "feat: HookRunner fires 출근/퇴근 hooks once per day with persisted dedupe"
```

---

### Task 2: Detached executor + AppState wiring

**Files:**

- Modify: `Sources/FlexTimer/HookRunner.swift` (fill in `launchDetached`)
- Modify: `Sources/FlexTimer/AppState.swift:49-72` (`start()` and `recompute(now:)`)
- Test: `Tests/FlexTimerTests/AppStateTests.swift` (one new test)

**Interfaces:**

- Consumes: `HookRunner` from Task 1 (`init(defaults:execute:)`, `evaluate(today:now:)`, `launchDetached(_:_:)` stub).
- Produces: `AppState.hookRunner: HookRunner?` — nil until `start()` runs, so tests that call `recompute` directly never launch scripts.

- [ ] **Step 1: Write the failing wiring test**

Add to `Tests/FlexTimerTests/AppStateTests.swift`:

```swift
    func testRecomputeFiresHooksWhenRunnerAttached() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        state.week = [WorkRecord(clockIn: d(2026, 7, 9, 9, 0), clockOut: nil, flexWorkedNet: nil)]
        var fired: [String] = []
        state.hookRunner = HookRunner(defaults: SettingsStore.defaults) { url, _ in
            fired.append(url.lastPathComponent)
        }
        state.recompute(now: d(2026, 7, 9, 10, 0))
        XCTAssertEqual(fired, ["on-clock-in"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppStateTests/testRecomputeFiresHooksWhenRunnerAttached`
Expected: build error — `value of type 'AppState' has no member 'hookRunner'`

- [ ] **Step 3: Wire HookRunner into AppState**

In `Sources/FlexTimer/AppState.swift`, add the property next to the other private lets (after `private let login = LoginWindowController()`, line 17):

```swift
    /// Attached in start() only, so unit tests calling recompute never launch scripts.
    var hookRunner: HookRunner?
```

In `start()`, before `Task { await refresh() }` (line 62):

```swift
        hookRunner = HookRunner()
```

In `recompute(now:)`, after `let record = todayRecord(now: now)` (line 66):

```swift
        hookRunner?.evaluate(today: record, now: now)
```

- [ ] **Step 4: Implement the real detached executor**

In `Sources/FlexTimer/HookRunner.swift`, replace the `launchDetached` stub:

```swift
    /// Fire-and-forget: launch the script detached, never wait or read output.
    /// Missing or non-executable script is silently skipped. Backgrounded
    /// children (e.g. `caffeinate &`) survive after the script exits.
    static func launchDetached(_ script: URL, _ env: [String: String]) {
        guard FileManager.default.isExecutableFile(atPath: script.path) else { return }
        let process = Process()
        process.executableURL = script
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, hook in hook }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: full suite passes, including `testRecomputeFiresHooksWhenRunnerAttached`

- [ ] **Step 6: Manual smoke test**

```bash
mkdir -p ~/Library/Application\ Support/칼퇴타이머/hooks
cat > ~/Library/Application\ Support/칼퇴타이머/hooks/on-clock-in <<'EOF'
#!/bin/zsh
echo "$KALTOE_EVENT $KALTOE_CLOCK_IN" >> /tmp/kaltoe-hook-test.log
EOF
chmod +x ~/Library/Application\ Support/칼퇴타이머/hooks/on-clock-in
# clear today's dedupe so the hook can fire (bundle id domain):
/usr/libexec/PlistBuddy -c print ~/Library/Preferences/com.perso.flextimer.plist 2>/dev/null | grep hookFired || true
defaults delete com.perso.flextimer "hookFired-clockIn-$(date +%F)" 2>/dev/null || true
swift run FlexTimer & sleep 20; kill %1
cat /tmp/kaltoe-hook-test.log
```

Expected: `/tmp/kaltoe-hook-test.log` contains one `clock-in <ISO date>` line (requires an active Flex session or a manual start entry for today; if neither exists, verify via the test suite only and note it in the task report). Clean up: `rm /tmp/kaltoe-hook-test.log` and remove the test hook if undesired.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlexTimer/HookRunner.swift Sources/FlexTimer/AppState.swift Tests/FlexTimerTests/AppStateTests.swift
git commit -m "feat: wire hook execution into AppState; detached Process executor"
```

---

### Task 3: README Hooks section

**Files:**

- Modify: `README.md` (new "Hooks" section after "Customizing Work Hours")

**Interfaces:**

- Consumes: behavior shipped in Tasks 1–2. No code.

- [ ] **Step 1: Add the Hooks section to README.md**

Insert after the "Customizing Work Hours" section:

````markdown
## Hooks

Run your own scripts when 칼퇴타이머 detects 출근 (clock-in) or 퇴근 (clock-out). Drop executables at:

```
~/Library/Application Support/칼퇴타이머/hooks/
├── on-clock-in
└── on-clock-out
```

Both are optional; a missing or non-executable file is skipped. Remember `chmod +x`.

Scripts receive environment variables:

- `KALTOE_EVENT` — `clock-in` or `clock-out`
- `KALTOE_CLOCK_IN` — clock-in time, ISO8601
- `KALTOE_CLOCK_OUT` — clock-out time, ISO8601 (clock-out only)

Semantics:

- Each hook fires **at most once per event per day**, even across app restarts. If the app launches after you already clocked in (e.g. Mac booted late), the hook still fires — late, but once.
- 퇴근 is detected via Flex sync, so the clock-out hook can lag up to ~10 minutes. Syncs happen on app launch, every 10 minutes, and on wake from sleep.
- Hooks are fire-and-forget: the app never waits on your script or reads its output. Backgrounded children (`caffeinate &`) keep running after the script exits.

Example — keep the Mac awake while at work, lock the screen and clean up after leaving:

```bash
# on-clock-in
#!/bin/zsh
caffeinate -d & echo $! > /tmp/kaltoe-caffeinate.pid
claude -p "prepare my morning briefing" > /dev/null 2>&1 &
```

```bash
# on-clock-out
#!/bin/zsh
[ -f /tmp/kaltoe-caffeinate.pid ] && kill "$(cat /tmp/kaltoe-caffeinate.pid)" 2>/dev/null
rm -f /tmp/kaltoe-caffeinate.pid
pmset displaysleepnow   # lock the screen (with the default "require password immediately")
```

The morning `caffeinate -d` conveniently guarantees the Mac is still awake when clock-out is detected. `pmset displaysleepnow` needs no special permissions.
````

- [ ] **Step 2: Verify formatting**

Run: `sed -n '/^## Hooks/,/^## /p' README.md | head -5`
Expected: the section renders where intended (after Customizing Work Hours).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README Hooks section with caffeinate/claude/lock-screen examples"
```
