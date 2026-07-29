# Covering HeadlessState: a KaltoeDaemonTests target

This is follow-up item 13, queued ahead of item 14 (typed throws) for a specific
reason: item 14 rewrites `HeadlessState.swift:25`, and nothing currently guards
it.

## Problem

`Package.swift` declares test targets for `KaltoeCore` and `FlexTimer` only.
**Nothing depends on `KaltoeDaemon`, so the entire target is uncovered** — and
the Linux daemon is what two of the four users actually run.

The uncovered code is not glue. `Sources/KaltoeDaemon/HeadlessState.swift` is a
hand-maintained duplicate of `AppState`'s refresh/compute semantics, and its own
doc comment makes two promises nothing verifies: "sync failure keeps last data,
dead session flips hasSession". It also assembles the `StatusLine` the Python
tray consumes, including the `hasSession ? … : nil` gating of `started`,
`leaveAt` and `weekOvertime` — precisely the optional NDJSON fields the tray's
menu rows read. A silent change there reaches Linux users as wrong menu rows
rather than a crash.

This gap already cost one incident this session: `fflush(nil)` deadlocked the
daemon's emit loop and passed both compile-green and 246 green tests, because no
test target reaches `KaltoeDaemon` at all.

## Approach

Add a `KaltoeDaemonTests` target, and give `HeadlessState` one constructor seam
so `refresh()` can be driven without a network.

`FlexClient` constructs its own ephemeral `URLSession` and exposes no seam of its
own, so `refresh()` has never been testable in either `HeadlessState` or
`AppState`. Injecting at the `HeadlessState` boundary is the smallest change that
makes the daemon's logic reachable.

**The key consequence: one seam covers both goals.** An earlier sketch of this
work assumed a pure `statusLine(...)` function would have to be extracted,
because every stored property is `private(set)` and even `@testable` cannot write
a private setter. That extraction is unnecessary. With the fetch injected, tests
set state up _through_ `refresh()` and read it back _through_ `status(now:)` — so
nothing is extracted, no access level is relaxed, and the tests exercise the real
path rather than a fragment. The assignment at lines 20-21 gets covered as a
side effect.

## Feasibility, verified before writing this

Three unknowns, each settled by a throwaway probe that was reverted:

1. **A test target can link an executable target whose entry point is top-level
   `main.swift` code.** Confirmed: the probe built and ran, and the daemon's loop
   did **not** start during the test. (`FlexTimerTests` already depends on the
   `FlexTimer` executable target, but that one uses `@main`, not top-level code.)
2. **`HeadlessState()` is constructible in a test.** Its `hasSession` initialiser
   calls `CookieVault.load()`; that returns nil under the test keychain service
   and does not hang or prompt.
3. **`ParseResult` is constructible from the test module.** It is a `public
struct` with **no explicit `public init`**, so its memberwise initialiser is
   internal to `KaltoeCore` — a plain `import` would not do. `@testable import
KaltoeCore` in the test file works, so **no production change to
   `ParseResult` is needed.**

## Components

### `Package.swift`

```swift
    .testTarget(name: "KaltoeDaemonTests", dependencies: ["KaltoeDaemon"], path: "Tests/KaltoeDaemonTests"),
```

### `Sources/KaltoeDaemon/HeadlessState.swift` — the seam

Replace the stored `private let client = FlexClient()` with an injected closure:

```swift
    /// Injected so tests can drive refresh()'s three outcomes without a network.
    /// FlexClient builds its own ephemeral URLSession and exposes no seam of its
    /// own, so this initialiser is the only place a fake can go in.
    private let fetchWeek: (Date, Date) async throws -> ParseResult

    init(fetchWeek: ((Date, Date) async throws -> ParseResult)? = nil) {
        let client = FlexClient()
        self.fetchWeek = fetchWeek ?? { try await client.fetchWeek(from: $0, to: $1) }
    }
```

`refresh()`'s single call site changes from `client.fetchWeek(from:to:)` to
`fetchWeek(weekStart, max(now, weekEnd))`. Nothing else in the type changes —
the catch ladder, the assignments, and `status(now:)` are all untouched.

A closure rather than a protocol, matching how `SessionNotifier(post:)`,
`LimitNotifier(post:)` and `HookRunner` already inject in this codebase. A
protocol would mean adding public API to `KaltoeCore` purely to serve tests.

The default argument means every production call site — `main.swift`'s
`HeadlessState()` — is unchanged.

### `Tests/KaltoeDaemonTests/HeadlessStateTests.swift`

`@MainActor final class`, because `HeadlessState` is `@MainActor`. Imports
`@testable import KaltoeCore` (for `ParseResult`'s internal memberwise init) and
`@testable import KaltoeDaemon`.

Four tests, each driving state through `refresh()` and asserting on
`status(now:)`:

1. **Successful refresh populates the status line.** Inject a fetch returning a
   `ParseResult` with one clock-in record. Assert `hasSession` true,
   `syncError` nil, `lastSync` non-nil, and that `status(now:)` emits non-nil
   `started`, `leaveAt` and `weekOvertime`.
2. **A session error flips `hasSession` and gates every optional field.** Inject a
   fetch throwing `FlexClient.FlexError.sessionExpired`. Assert `hasSession`
   false and that `status(now:)` returns `nil` for `started`, `leaveAt` **and**
   `weekOvertime`. This is the assertion that pins the NDJSON contract the tray
   reads — all three are gated on `hasSession`, and nothing currently checks it.
3. **`.noSession` behaves identically.** The `where` clause on line 25 matches
   two cases; a test for only one would leave half the condition unpinned.
4. **A non-session error keeps the last known data.** Inject a fetch that
   succeeds on its first call and throws `URLError(.timedOut)` on its second.
   After the second `refresh()`, assert `syncError` is set **and** `lastSync` and
   the week's records survive from the first. This is the "keeps last data"
   half of the type's doc comment.

Test 4 needs a fetch whose behaviour differs per call; a closure capturing a
mutable counter in the test provides that without any fake-object machinery.

**Two fixture details that will otherwise produce confusing failures.**

The injected record's `clockIn` must fall on the **same calendar day** as the
`now` passed to `status(now:)`, and inside the **same Monday-start week**.
`weekData.todayRecord(now:)` matches on calendar day and
`weekIncludingManual(now:)` filters to the week, so a mismatch makes `today` nil
and silently gates `started` and `leaveAt` to nil — which reads as the gating
test passing for the wrong reason rather than as a fixture error. Pick one fixed
date for both, e.g. a record clocking in on 2026-07-29 with `status(now:)` called
later the same day; the pair is then self-consistent regardless of the real clock.

Note also that `refresh()` sets `lastSync` from the real `Date()`, not from any
injected value, so assert only that it is non-nil.

Each test must point `SettingsStore.defaults` at a throwaway
`UserDefaults(suiteName:)` in `setUp`, as every existing test in this repo does.
`status(now:)` reads `SettingsStore.rules`, so without it a stray `defaults
write` on the developer's machine would change the expected leave time.

## Data flow

```
test injects fetchWeek closure
            │
    HeadlessState.refresh()
            │
   ┌────────┼────────────────┐
 success   FlexError      other error
   │      (.noSession /       │
   │       .sessionExpired)   │
weekData,      │          syncError set,
lastSync,   hasSession    weekData & lastSync
hasSession=true  = false    preserved
   └────────┼────────────────┘
            │
     status(now:) ──> StatusLine, asserted by the test
```

## Error handling

No new failure paths. The injected closure's errors are exactly the errors
`FlexClient.fetchWeek` already throws, routed through the same unmodified catch
ladder.

## Testing

The four tests above are the deliverable. Expected suite total afterwards:
**140 on macOS** (136 + 4) and **114 on Linux** (110 + 4) — the daemon target
builds on both platforms, so the new tests run on both, which is the point.

Linux verification uses the documented command, with `-e TZ=Asia/Seoul`; the repo
records that 13 tests are date-shifted under the container's default UTC.

## Verification

1. `rm -rf .build && swift build --build-tests` — **once**, cold. Zero warnings.
   `swift build` alone does not compile test targets, and a warm build re-emits
   nothing; that combination hid four real warnings earlier this session.
2. `swift test` → **140, 0 failures**.
3. Linux `swift test` in Docker with `-e TZ=Asia/Seoul` → **114, 0 failures**.
4. `./scripts/build-linux.sh` → succeeds. `Package.swift` is being edited and the
   Linux toolchain parses it.

## Out of scope

- **Giving `AppState` the same seam.** It has the identical gap — same
  `private let client = FlexClient()`, same untested `refresh()`, and item 14
  edits its catch ladder too. It is the macOS app rather than the daemon, and
  this item was scoped to close the daemon blind spot. Recorded as a follow-up.
- Testing `main.swift`'s emit loop. Still unreachable by any test target; the
  Docker smoke check is the tool for that, and promoting it into `scripts/` was
  deliberately declined.
- Adding a `public init` to `ParseResult` — unnecessary, per feasibility item 3.
- Any change to `status(now:)`, the catch ladder, or the `StatusLine` shape.
