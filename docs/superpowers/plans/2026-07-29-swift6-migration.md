# Swift 6 Migration & macOS 26 Floor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise the project to `swift-tools-version:6.0` with a macOS 26 floor, adopt the Swift 6 language mode, and delete the compatibility code the old macOS 13 floor required.

**Architecture:** The manifest bump makes the Swift 6 language mode the default, which surfaces a fixed, already-enumerated set of concurrency errors. Task 1 applies the whole macOS-side change atomically — the package does not build between the manifest edit and the last annotation, so it cannot be split. Task 2 verifies Linux in Docker, where `#if os(macOS)`-excluded code will produce at least one error the macOS compiler cannot see.

**Tech Stack:** Swift 6.3 locally / Swift 6.1 in Docker, SwiftPM, XCTest, Docker (`swift:6.1-noble`).

Spec: `docs/superpowers/specs/2026-07-29-swift6-migration-design.md`

## This plan is transcription, not discovery

Every change in Task 1 was established empirically before this plan was written:
the bump was applied locally, the compiler iterated to a clean build, and the
result reverted. **`swift build` and `swift test` reached 136 tests, 0 failures,
0 warnings under the Swift 6 language mode.** The code below is that verified
diff.

If you find yourself needing a change that is _not_ listed here, that is
significant — report it rather than absorbing it, because it means the verified
state and the current tree have diverged.

## Global Constraints

- Target toolchain: local Swift 6.3, Docker `swift:6.1-noble`. No new dependencies.
- Exact manifest values: `// swift-tools-version:6.0` and `platforms: [.macOS("26.0")]`.
- **`platforms` must use the string form `"26.0"`, never `.macOS(.v26)`.** The
  SwiftPM inside `swift:6.1-noble` predates macOS 26 and has no `.v26` enum
  case; the enum form compiles locally and breaks the Linux build.
- Tools version is **6.0**, not 6.2. 6.2 is only needed for `defaultIsolation`,
  which is a queued sub-project with its own Docker image bump.
- `LSMinimumSystemVersion` in `scripts/bundle.sh` becomes `26.0`.
- **Do not add `Sendable` to `WeekData`**, and do not add it to the caseless
  namespace enums (`CookieVault`, `SettingsStore`, `WorkCalculator`,
  `Formatting`, `FlexAPIConfig`). The verified clean build annotates neither.
- **Do not add a `deinit` to `AppState`**; do not change the 600s poll interval.
- Test baselines that must be met exactly:
  - macOS `swift test` → **136 tests, 0 failures**
  - Linux `swift test` in Docker → **110 tests, 0 failures** (Linux runs fewer
    because the `FlexTimer` target is macOS-only)
- Linux test runs **require `-e TZ=Asia/Seoul`**. The repo documents that 13
  tests are date-shifted under the container's default UTC; omitting it produces
  failures that look like migration damage and are not.
- Commit messages must end with the trailer
  `Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ`.
- Markdown must be patched via Bash, never Edit/Write — a prettier `PostToolUse`
  hook reflows it. No markdown changes are expected in this plan.

## File Structure

| File                                        | Change                                                           | Task |
| ------------------------------------------- | ---------------------------------------------------------------- | ---- |
| `Package.swift`                             | tools version, platform floor                                    | 1    |
| `Sources/KaltoeCore/SettingsStore.swift`    | `nonisolated(unsafe)` on `defaults`                              | 1    |
| `Sources/KaltoeCore/CookieVault.swift`      | `nonisolated(unsafe)` on `service`; `Sendable` on `StoredCookie` | 1    |
| `Sources/KaltoeCore/FlexClient.swift`       | `Sendable` on the class and on `FlexError`                       | 1    |
| `Sources/KaltoeCore/DisplayState.swift`     | `Sendable` on `Urgency`, `MenuDisplay`, `DisplayState`           | 1    |
| `Sources/KaltoeCore/FlexRecordParser.swift` | `Sendable` on `ParseResult`                                      | 1    |
| `Sources/KaltoeCore/MenuLabelStyle.swift`   | `Sendable` on `MenuLabelStyle`                                   | 1    |
| `Sources/KaltoeCore/StatusLine.swift`       | `Sendable` on `StatusLine`                                       | 1    |
| `Sources/KaltoeCore/WorkCalculator.swift`   | `Sendable` on `WorkRules`, `WorkRecord`                          | 1    |
| `Sources/FlexTimer/SessionNotifier.swift`   | `@MainActor` + `@preconcurrency` on the delegate                 | 1    |
| `Sources/FlexTimer/MenuBarView.swift`       | delete the `#available(macOS 14.0, *)` fork                      | 1    |
| `scripts/bundle.sh`                         | `LSMinimumSystemVersion` → `26.0`                                | 1    |
| —                                           | Linux-only concurrency fixes discovered in Docker                | 2    |

---

### Task 1: The macOS-side migration

Atomic by necessity: the package does not compile between the manifest edit and
the final annotation, so there is no intermediate green state to commit.

**Files:** all twelve rows above with Task = 1.

**Interfaces:**

- Produces: nothing new. Every change is a manifest edit, an isolation
  annotation, a protocol conformance, or a deletion. No signature changes, so
  Task 2 consumes nothing from this task beyond a building package.

- [ ] **Step 1: Bump the manifest**

In `Package.swift`, line 1 and the `platforms:` line:

```swift
// swift-tools-version:6.0
```

```swift
    platforms: [.macOS("26.0")],
```

The string form is required — see Global Constraints.

- [ ] **Step 2: Confirm the expected breakage**

Run: `swift build`
Expected: FAIL with, among others,
`static property 'defaults' is not concurrency-safe because it is nonisolated global shared mutable state`
and the same for `'service'`.

This step exists to confirm the language mode actually flipped. If the build
_passes_ here, the manifest edit did not take effect and everything after this
is meaningless — stop and report it.

- [ ] **Step 3: Annotate the two mutable statics**

`Sources/KaltoeCore/SettingsStore.swift`:

```swift
    nonisolated(unsafe) public static var defaults = UserDefaults.standard
```

`Sources/KaltoeCore/CookieVault.swift` (in the `#if os(macOS)` branch):

```swift
    nonisolated(unsafe) public static var service = defaultService
```

Both are mutable so tests can inject a throwaway `UserDefaults(suiteName:)` and
a sacrificial keychain service. `nonisolated(unsafe)` states that contract
rather than pretending the state is safe. Replacing it with real isolation is a
queued sub-project, deliberately not done here.

- [ ] **Step 4: Make `FlexClient` and its error `Sendable`**

`Sources/KaltoeCore/FlexClient.swift`:

```swift
public final class FlexClient: Sendable {
```

```swift
    public enum FlexError: Error, Equatable, Sendable { case noSession, sessionExpired, badResponse }
```

`FlexClient`'s only stored property is `private let session: URLSession`, which
is already `Sendable`, so the conformance is free. This one change fixes
`sending 'self.client' risks causing data races` in **both** `AppState` and
`HeadlessState` — both are `@MainActor` classes awaiting the client's nonisolated
`fetchWeek`. Do not annotate those two call sites instead; it would not work.

- [ ] **Step 5: Make the public value types `Sendable`**

Add `, Sendable` to each existing conformance list:

`Sources/KaltoeCore/DisplayState.swift`:

```swift
public enum Urgency: String, Equatable, Sendable {
public struct MenuDisplay: Equatable, Sendable {
public enum DisplayState: Equatable, Sendable {
```

`Sources/KaltoeCore/CookieVault.swift`:

```swift
public struct StoredCookie: Codable, Equatable, Sendable {
```

`Sources/KaltoeCore/FlexRecordParser.swift`:

```swift
public struct ParseResult: Equatable, Sendable {
```

`Sources/KaltoeCore/MenuLabelStyle.swift`:

```swift
public enum MenuLabelStyle: Equatable, Sendable {
```

`Sources/KaltoeCore/StatusLine.swift`:

```swift
public struct StatusLine: Codable, Equatable, Sendable {
```

`Sources/KaltoeCore/WorkCalculator.swift`:

```swift
public struct WorkRules: Codable, Equatable, Sendable {
public struct WorkRecord: Equatable, Sendable {
```

These need explicit conformance because **public types get no implicit
`Sendable` inference across module boundaries** — which is why `Sources` builds
clean while the _test_ targets fail without them.

`WeekData` is deliberately absent. The verified clean build does not annotate
it; do not add it.

- [ ] **Step 6: Fix the notification delegate**

`Sources/FlexTimer/SessionNotifier.swift` — **both** annotations are needed:

```swift
@MainActor
final class NotificationClickDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
```

Each alone is insufficient, established by trying them in sequence: without
`@MainActor` the `static let shared` is unsafe global state; with `@MainActor`
alone the build fails with `conformance of 'NotificationClickDelegate' to
protocol 'UNUserNotificationCenterDelegate' crosses into main actor-isolated
code`.

- [ ] **Step 7: Build and run the macOS suite**

Run: `swift build && swift test`
Expected: build clean with **zero warnings**, and **136 tests, 0 failures**.

136 is exact. A different number means behaviour moved, which this change must
not do — stop and report it.

- [ ] **Step 8: Delete the availability fork**

`Sources/FlexTimer/MenuBarView.swift`. The fork is a `@ViewBuilder` wrapper
around a `highContrastRowBase`; the two collapse into one property. Delete this
entire block, comment included — the comment describes a macOS 13 fallback that
no longer exists:

```swift
    /// `.isToggle` is macOS 14+ and the deployment target is 13. On 13 the row still
    /// announces as a named button carrying an on/off value, which is the part that
    /// matters; only the trait refinement is unavailable. Split so neither path
    /// needs an AnyView.
    @ViewBuilder private var highContrastRow: some View {
        if #available(macOS 14.0, *) {
            highContrastRowBase.accessibilityAddTraits(.isToggle)
        } else {
            highContrastRowBase
        }
    }

    private var highContrastRowBase: some View {
```

and replace it with a single declaration:

```swift
    private var highContrastRow: some View {
```

Then append `.accessibilityAddTraits(.isToggle)` as the last modifier on that
property, after the existing `.accessibilityValue(...)` line, so the property now
ends:

```swift
        // Pointer tooltip. Not an accessibility label, and not a substitute for one.
        .help("Renders the icon and time at full contrast so they stay legible on the menu bar of a display that doesn't have focus.")
        .accessibilityValue(state.highContrastOnInactiveDisplays ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
```

Keeping the name `highContrastRow` means `body` needs no change — it already
references that property.

Everything else about the row stays exactly as it is: the verbatim title
`Stay readable when unfocused`, `.allowsHitTesting(false)` and
`.accessibilityHidden(true)` on the trailing `Toggle` with their explanatory
comments, the `.help(...)` tooltip, and `.accessibilityValue(...)`.

This is the only availability fork in the codebase.

- [ ] **Step 9: Raise the bundle's minimum system version**

`scripts/bundle.sh`, the `Info.plist` heredoc:

```
  <key>LSMinimumSystemVersion</key><string>26.0</string>
```

- [ ] **Step 10: Rebuild, retest, and bundle**

Run: `swift build && swift test`
Expected: clean, **136 tests, 0 failures**, no warnings.

Run: `./scripts/bundle.sh`
Expected: succeeds. Then confirm the floor actually landed in the built bundle:

```bash
grep -A0 LSMinimumSystemVersion build/칼퇴타이머.app/Contents/Info.plist
```

Expected: `26.0`.

**Do not launch the app.** It is in daily use, and `AppState.start()` attaches
`HookRunner`, so a second instance would fire the user's clock-in/out hook
scripts against their live workday.

- [ ] **Step 11: Commit**

```bash
git add Package.swift scripts/bundle.sh Sources/KaltoeCore/ Sources/FlexTimer/
git commit -m "build: Swift 6 language mode and a macOS 26 floor

Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ"
```

---

### Task 2: Linux verification

The macOS compiler cannot see `#if os(macOS)`-excluded code, so Task 1 passing
green proves nothing about Linux. `CookieVault` is split `#if os(macOS)` /
`#else`, and the Linux branch declares its own
`public static var sessionFileOverride: URL?` — mutable global state that will
need the same treatment, plus possibly more.

**Files:**

- Modify: `Sources/KaltoeCore/CookieVault.swift` (the `#else` / Linux branch)
- Modify: whatever else the Linux compiler reports

**Interfaces:**

- Consumes: a macOS-green package from Task 1.
- Produces: nothing.

Docker is running (29.6.2) and pre-change baselines were captured: the product
build succeeds with one pre-existing warning (`CookieVault.swift:110`, unused
result of `createFile`) plus linker noise from `libFoundationEssentials`, and the
Linux suite runs **110 tests, 0 failures**. Neither warning is ours — anything
new is.

- [ ] **Step 1: Run the Linux product build**

```bash
./scripts/build-linux.sh
```

Expected: likely FAIL, with at least
`static property 'sessionFileOverride' is not concurrency-safe because it is nonisolated global shared mutable state`.

Record every error verbatim in your report — this is the error set the macOS
build could not reveal, and it is the reason this task exists.

- [ ] **Step 2: Annotate the Linux-only mutable static**

`Sources/KaltoeCore/CookieVault.swift`, in the `#else` (Linux) branch:

```swift
    nonisolated(unsafe) public static var sessionFileOverride: URL?
```

Same reasoning as the macOS statics: it is mutable so tests can redirect the
session file, and `nonisolated(unsafe)` states that contract.

- [ ] **Step 3: Re-run the Linux product build**

```bash
./scripts/build-linux.sh
```

Expected: succeeds, with only the two pre-existing warnings named above.

If further concurrency errors appear, fix them following the same patterns as
Task 1 — `nonisolated(unsafe)` for deliberately-mutable statics, `Sendable` for
value types — and report each one, since none of them were in the verified
macOS set.

- [ ] **Step 4: Run the Linux test suite**

This is the step `build-linux.sh` does not cover: it builds only the
`kaltoe-core` product, so it never compiles the test targets — and the test
targets are exactly where the `Sendable`-across-module errors appeared on macOS.

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e TZ=Asia/Seoul swift:6.1-noble swift test --scratch-path .build-linux
```

Expected: **110 tests, 0 failures.**

`-e TZ=Asia/Seoul` is required. Without it 13 tests are date-shifted under the
container's default UTC and fail in a way that looks like migration damage.

- [ ] **Step 5: Re-run the macOS suite**

Run: `swift test`
Expected: **136 tests, 0 failures.**

Any Linux fix that touches shared (non-`#if`-guarded) code could regress macOS;
this step catches that.

- [ ] **Step 6: Commit**

```bash
git add Sources/KaltoeCore/
git commit -m "build: Swift 6 concurrency fixes for the Linux target

Claude-Session: https://claude.ai/code/session_01C1YEBWgyNhAFt9BSELM4eJ"
```

If Step 1 revealed no errors at all and no files changed, skip the commit and
say so in your report — that would mean the Linux branch needed nothing, which
would be a surprise worth stating plainly rather than inventing a change to
justify the task.

---

## Queued follow-ups

Recorded in the spec, deliberately not in this plan, each needing this one
landed first:

2. **Typed throws** — `throws(FlexError)` on `FlexClient.fetchWeek`, letting
   both `refresh()` implementations replace the
   `catch let e as FlexClient.FlexError where …` cast with a plain exhaustive
   `catch`.
3. **Replace both `nonisolated(unsafe)` hatches with real isolation** — the
   principled version of this plan's compromise; reshapes test injection.
4. **`defaultIsolation: MainActor`** — needs tools version 6.2 and a Docker
   image newer than `swift:6.1-noble`, and **must apply to the `FlexTimer`
   target only**. `KaltoeCore` has 29 pure-computation `public static func`s and
   its tests are deliberately not `@MainActor`.
