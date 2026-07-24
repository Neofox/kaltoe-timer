# Linux Hook Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fire the existing `on-clock-in` / `on-clock-out` hook scripts on the Linux build (KaltoeDaemon), matching macOS semantics exactly.

**Architecture:** Approach B from `docs/superpowers/specs/2026-07-24-linux-hooks-design.md` — keep `HookRunner`'s `UserDefaults` dedupe and add an explicit `synchronize()` on Linux (empirically required: bare `set()` never persists on Linux; `synchronize()` flushes to `~/.config/kaltoe-core.plist` and survives SIGKILL). Platform-split `hooksDirectory` to `~/.config/kaltoe-timer/hooks/` on Linux via a shared `LinuxPaths.configDirectory` helper, and call `evaluate()` from the daemon's 1-second loop.

**Tech Stack:** Swift 6.1 (SwiftPM), XCTest, Docker image `swift:6.1-noble` for Linux build/test.

## Global Constraints

- macOS behavior must stay byte-identical: macOS hooks dir unchanged (`~/Library/Application Support/칼퇴타이머/hooks/`), no `synchronize()` on macOS, no change to `AppState` or `HookRunner` public API.
- Linux hooks dir: `$KALTOE_CONFIG_DIR/hooks` if the env var is set, else `~/.config/kaltoe-timer/hooks` — same resolution as `CookieVault.sessionFileURL`.
- Linux tests run inside Docker with `-e TZ=Asia/Seoul` (13 tests are date-shifted under UTC, per `scripts/build-linux.sh` comment).
- All commands below run from the repo root `/Users/3i-a1-2025-005/Developer/perso/timer`.

---

### Task 1: `LinuxPaths.configDirectory` helper, adopted by `CookieVault`

Pure refactor — single source of truth for the Linux config dir before `HookRunner` starts using it. No behavior change, covered by existing `CookieVaultTests`.

**Files:**

- Create: `Sources/KaltoeCore/LinuxPaths.swift`
- Modify: `Sources/KaltoeCore/CookieVault.swift:80-87` (`sessionFileURL`)

**Interfaces:**

- Produces: `LinuxPaths.configDirectory: URL` (internal, `#if !os(macOS)` only) — Task 2 calls it from `HookRunner.hooksDirectory`.

- [ ] **Step 1: Create the helper**

`Sources/KaltoeCore/LinuxPaths.swift`:

```swift
import Foundation

#if !os(macOS)
/// Single source of truth for the Linux config directory, shared by
/// CookieVault (session.json) and HookRunner (hooks/):
/// $KALTOE_CONFIG_DIR if set, else ~/.config/kaltoe-timer.
enum LinuxPaths {
    static var configDirectory: URL {
        ProcessInfo.processInfo.environment["KALTOE_CONFIG_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/kaltoe-timer", isDirectory: true)
    }
}
#endif
```

- [ ] **Step 2: Point `CookieVault.sessionFileURL` at it**

In `Sources/KaltoeCore/CookieVault.swift`, replace the body of `sessionFileURL` (Linux block, currently lines 80–87):

```swift
    static var sessionFileURL: URL {
        if let sessionFileOverride { return sessionFileOverride }
        return LinuxPaths.configDirectory.appendingPathComponent("session.json")
    }
```

The `sessionFileOverride` test seam and the doc comment above the enum stay untouched.

- [ ] **Step 3: Verify macOS build and tests are unaffected**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (the new file is compiled out on macOS; `swift build` succeeding is the real check here).

- [ ] **Step 4: Verify the Linux build and tests still pass**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e TZ=Asia/Seoul swift:6.1-noble swift test --scratch-path .build-linux 2>&1 | tail -3
```

Expected: all tests pass (identical count to before the change).

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/LinuxPaths.swift Sources/KaltoeCore/CookieVault.swift
git commit -m "refactor: extract LinuxPaths.configDirectory shared by CookieVault"
```

---

### Task 2: `HookRunner` — Linux hooks dir + `synchronize()` dedupe persistence

**Files:**

- Modify: `Sources/KaltoeCore/HookRunner.swift:10-13` (`hooksDirectory`), `:42-51` (`markFiredIfNeeded`)
- Test: `Tests/KaltoeCoreTests/HookRunnerTests.swift:31,46` (path assertions), plus one new test

**Interfaces:**

- Consumes: `LinuxPaths.configDirectory` from Task 1.
- Produces: `HookRunner.hooksDirectory` resolving to `<config dir>/hooks` on Linux; `evaluate(today:now:)` signature unchanged (Task 3 calls it).

- [ ] **Step 1: Update the two path assertions to be platform-conditional and add the Linux override test**

In `Tests/KaltoeCoreTests/HookRunnerTests.swift`, replace line 31:

```swift
        XCTAssertTrue(fired[0].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-in"))
```

with:

```swift
        #if os(macOS)
        XCTAssertTrue(fired[0].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-in"))
        #else
        XCTAssertTrue(fired[0].script.path.hasSuffix("kaltoe-timer/hooks/on-clock-in"))
        #endif
```

Replace line 46:

```swift
        XCTAssertTrue(fired[1].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-out"))
```

with:

```swift
        #if os(macOS)
        XCTAssertTrue(fired[1].script.path.hasSuffix("칼퇴타이머/hooks/on-clock-out"))
        #else
        XCTAssertTrue(fired[1].script.path.hasSuffix("kaltoe-timer/hooks/on-clock-out"))
        #endif
```

Add at the end of the class (before the closing brace):

```swift
    #if !os(macOS)
    func testHooksDirectoryHonorsConfigDirOverride() {
        setenv("KALTOE_CONFIG_DIR", "/tmp/kaltoe-test-config", 1)
        defer { unsetenv("KALTOE_CONFIG_DIR") }
        XCTAssertEqual(HookRunner.hooksDirectory.path, "/tmp/kaltoe-test-config/hooks")
    }
    #endif
```

(XCTest runs serially and the `defer` unsets the var, so this cannot leak into other tests. If the Docker run in Step 2 shows the env override NOT taking effect — corelibs caching `ProcessInfo.environment` — change the test to assert the default branch instead: `XCTAssertTrue(HookRunner.hooksDirectory.path.hasSuffix(".config/kaltoe-timer/hooks"))` with no setenv, and note it; do not fight the caching.)

- [ ] **Step 2: Run the Linux tests to verify the new expectations fail**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e TZ=Asia/Seoul swift:6.1-noble swift test --scratch-path .build-linux \
  --filter HookRunnerTests 2>&1 | tail -15
```

Expected: FAIL — `testClockInFiresOnceWithEnv`, `testClockOutFiresOnceAfterClockOutAppears` (paths still resolve under `칼퇴타이머`), and `testHooksDirectoryHonorsConfigDirOverride`.

- [ ] **Step 3: Run the macOS tests to verify they still pass**

Run: `swift test --filter HookRunnerTests 2>&1 | tail -3`
Expected: PASS (macOS branches assert the unchanged path; the new test is compiled out).

- [ ] **Step 4: Implement the platform split and synchronize**

In `Sources/KaltoeCore/HookRunner.swift`, replace `hooksDirectory` (lines 10–13):

```swift
    public static var hooksDirectory: URL {
        #if os(macOS)
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("칼퇴타이머/hooks", isDirectory: true)
        #else
        LinuxPaths.configDirectory.appendingPathComponent("hooks", isDirectory: true)
        #endif
    }
```

In `markFiredIfNeeded`, after `defaults.set(true, forKey: key)` (line 49), insert:

```swift
        #if !os(macOS)
        // Linux corelibs never flushes UserDefaults on set(); without this,
        // hooks re-fire on every daemon restart.
        defaults.synchronize()
        #endif
```

Also update the class doc comment (lines 4–8) to mention both platforms:

```swift
/// Runs user hook scripts on detected 출근/퇴근, at most once per event per day.
///
/// Scripts are optional executables in `~/Library/Application Support/칼퇴타이머/hooks/`
/// on macOS, `~/.config/kaltoe-timer/hooks/` on Linux (`on-clock-in`, `on-clock-out`).
/// Dedupe state persists in UserDefaults as `hookFired-<event>-yyyy-MM-dd`, so app
/// restarts never re-fire, but an app launched after the real event still fires
/// once (late detection).
```

- [ ] **Step 5: Run Linux and macOS tests to verify they pass**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e TZ=Asia/Seoul swift:6.1-noble swift test --scratch-path .build-linux 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: PASS on both (full suites, not just the filter — CookieVault shares `LinuxPaths` now).

- [ ] **Step 6: Commit**

```bash
git add Sources/KaltoeCore/HookRunner.swift Tests/KaltoeCoreTests/HookRunnerTests.swift
git commit -m "feat: hook scripts on Linux — config-dir hooks path, synchronize dedupe"
```

---

### Task 3: Wire `HookRunner` into the daemon loop

**Files:**

- Modify: `Sources/KaltoeDaemon/main.swift:26-49` (the main `Task` block)

**Interfaces:**

- Consumes: `HookRunner()` / `evaluate(today:now:)` from Task 2; `HeadlessState.weekData.todayRecord(now:)` (existing).

- [ ] **Step 1: Add the runner and the per-tick evaluate call**

In `Sources/KaltoeDaemon/main.swift`, the `Task { @MainActor in` block currently starts:

```swift
Task { @MainActor in
    let state = HeadlessState()
    let encoder = StatusLine.encoder()
```

Add the runner after `state`:

```swift
Task { @MainActor in
    let state = HeadlessState()
    let hookRunner = HookRunner()
    let encoder = StatusLine.encoder()
```

Then, inside the `while true` loop, mirror `AppState.recompute` (which evaluates before computing display) by inserting one line between `let now = Date()` and `let line = state.status(now: now)`:

```swift
        let now = Date()
        hookRunner.evaluate(today: state.weekData.todayRecord(now: now), now: now)
        let line = state.status(now: now)
```

No session gate — macOS has none either; with no session there is no record and `evaluate` no-ops.

- [ ] **Step 2: Verify the Linux daemon builds**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  swift:6.1-noble swift build --product kaltoe-core --scratch-path .build-linux 2>&1 | tail -2
```

Expected: `Build complete!`

- [ ] **Step 3: Verify the macOS build still compiles everything**

Run: `swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 4: Smoke-test hook firing end-to-end in Docker**

The daemon needs a Flex session to produce records, which Docker doesn't have — so smoke-test the components the daemon composes instead: run a tiny script that uses `HookRunner` exactly as the daemon does and confirm a real script file fires once across two _processes_ (the dedupe-persistence property the whole approach hinges on):

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e TZ=Asia/Seoul swift:6.1-noble bash -c '
set -e
mkdir -p /tmp/.config/kaltoe-timer/hooks
printf "#!/bin/bash\necho fired-\$KALTOE_EVENT >> /tmp/hook.log\n" > /tmp/.config/kaltoe-timer/hooks/on-clock-in
chmod +x /tmp/.config/kaltoe-timer/hooks/on-clock-in
cat > /tmp/smoke.swift <<EOF
import Foundation
import KaltoeCore
let record = WorkRecord(clockIn: Date(), clockOut: nil, flexWorkedNet: nil)
HookRunner().evaluate(today: record, now: Date())
Thread.sleep(forTimeInterval: 0.5) // let the detached script run
EOF
swift build --scratch-path .build-linux
swiftc -I .build-linux/debug/Modules -L .build-linux/debug -lKaltoeCore \
  -o /tmp/kaltoe-core-smoke /tmp/smoke.swift 2>/dev/null || {
  echo "static-link fallback:"; swift run --scratch-path .build-linux kaltoe-core --help 2>/dev/null || true; }
[ -x /tmp/kaltoe-core-smoke ] && /tmp/kaltoe-core-smoke && /tmp/kaltoe-core-smoke
cat /tmp/hook.log
echo "---"; ls /tmp/.config/*.plist'
```

Expected: `/tmp/hook.log` contains exactly ONE `fired-clock-in` line despite two smoke-binary runs, and a `.plist` exists under `/tmp/.config/` (named after the smoke binary). If the `swiftc` link line fails in this image, skip the smoke test and rely on `HookRunnerTests` + the persistence experiment already recorded in the spec — do not burn time on link flags.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeDaemon/main.swift
git commit -m "feat: fire clock-in/out hooks from the Linux daemon loop"
```

---

### Task 4: Document hooks in README-linux.md

**Files:**

- Modify: `linux/README-linux.md` (add Hooks section before Uninstall; extend Uninstall)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add the Hooks section and update Uninstall**

In `linux/README-linux.md`, insert before the `## Uninstall` heading:

```markdown
## Hooks

Run your own scripts when 칼퇴타이머 detects clock-in (출근) or clock-out
(퇴근). Drop executables at:

    ~/.config/kaltoe-timer/hooks/
    ├── on-clock-in
    └── on-clock-out

Both are optional; a missing or non-executable file is skipped. Remember
`chmod +x`.

Environment variables passed to the script:

- `KALTOE_EVENT` — `clock-in` or `clock-out`
- `KALTOE_CLOCK_IN` — clock-in time, ISO8601 (UTC)
- `KALTOE_CLOCK_OUT` — clock-out time, ISO8601 (UTC) (clock-out only)

Behavior:

- Each hook fires **at most once per event per day**, even across restarts.
  If the app starts after you already clocked in, the hook still fires —
  late, but once.
- Both events are detected via Flex sync (there is no manual start entry on
  Linux), so hooks can lag up to ~10 minutes behind the real clock-in/out.
- A clock-out that is only detected after midnight does not fire — the day
  it belonged to has already rolled over.
- Fire-and-forget: the app never waits on your script or reads its output.
  Backgrounded children keep running after the script exits.

Example — keep the machine awake while at work, lock the screen after
leaving:

`on-clock-in`:

    #!/bin/bash
    systemd-inhibit --what=idle --why="kaltoe: at work" sleep infinity &
    echo $! > /tmp/kaltoe-inhibit.pid

`on-clock-out`:

    #!/bin/bash
    [ -f /tmp/kaltoe-inhibit.pid ] && kill "$(cat /tmp/kaltoe-inhibit.pid)" 2>/dev/null
    rm -f /tmp/kaltoe-inhibit.pid
    loginctl lock-session
```

Then replace the Uninstall command:

```markdown
    rm -rf ~/.local/share/kaltoe-timer ~/.config/kaltoe-timer \
           ~/.config/kaltoe-core.plist ~/.config/autostart/kaltoe-timer.desktop
```

- [ ] **Step 2: Commit**

```bash
git add linux/README-linux.md
git commit -m "docs: hooks section in README-linux (dir, env vars, examples)"
```

---

### Task 5: Full verification and release tarball

**Files:** none created; produces `build/kaltoe-timer-linux-x86_64.tar.gz`.

**Interfaces:** none.

- [ ] **Step 1: Full macOS test suite**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, zero failures.

- [ ] **Step 2: Full Linux test suite**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e TZ=Asia/Seoul swift:6.1-noble swift test --scratch-path .build-linux 2>&1 | tail -3
```

Expected: PASS, zero failures.

- [ ] **Step 3: Build the release tarball**

Run: `./scripts/build-linux.sh`
Expected: ends with `Built build/kaltoe-timer-linux-x86_64.tar.gz`.

- [ ] **Step 4: Confirm the tarball contains the updated README**

Run: `tar -xzOf build/kaltoe-timer-linux-x86_64.tar.gz kaltoe-timer-linux/README-linux.md | grep -c "on-clock-in"`
Expected: `2` or more (hooks section present).

- [ ] **Step 5: Done — hand off**

No commit (build artifacts are not tracked). Tell the user the tarball path so they can send it to their friend, who re-runs `install.sh` and creates `~/.config/kaltoe-timer/hooks/`.
