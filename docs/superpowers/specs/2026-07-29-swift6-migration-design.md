# Swift 6 migration and a macOS 26 floor

This is sub-project 1 of four. The user asked to "make use of the new features of
Swift 6", which decomposes into four independently valuable, independently
testable changes with a strict order. This spec covers only the first. The
others are recorded under Queued follow-ups below so they stay deliberate
projects rather than constraints somebody rediscovers.

## Problem

The project declares `swift-tools-version:5.9` and `platforms: [.macOS(.v13)]`,
with `LSMinimumSystemVersion` 13.0 in the bundled `Info.plist`. Every developer
and all four users are on macOS 26, so the macOS 13 floor buys nothing and
actively costs something: it forced an `#available(macOS 14.0, *)` fork in
`MenuBarView` to use `.accessibilityAddTraits(.isToggle)`, and it silently
constrains every future API choice.

Raising the floor also means opting into the Swift 6 language mode, since
`swift-tools-version:6.0` makes it the default. That is wanted, not incidental.

## Approach

Raise the floor, adopt the Swift 6 language mode, and delete the compatibility
code the old floor required.

The concurrency work below is **not speculative**. It was established by
performing the bump locally, iterating the compiler to a clean build, and then
reverting: `swift build` and `swift test` reached 136 tests, 0 failures, 0
warnings under the Swift 6 language mode. What follows is the observed error
set, in the order the compiler surfaces it.

## Components

### `Package.swift`

```swift
// swift-tools-version:6.0
platforms: [.macOS("26.0")],
```

**The string form is deliberate.** `scripts/build-linux.sh` builds inside
`swift:6.1-noble`, whose SwiftPM predates macOS 26 and has no `.v26` enum case.
Writing `.macOS(.v26)` would compile on this machine and break the Linux build.
`SupportedPlatform.macOS(_ versionString:)` is version-agnostic and parses on
both toolchains.

Tools version stays at **6.0**, not 6.2. 6.2 is required for
`defaultIsolation`, which is sub-project 4 and carries a Docker image bump.

### Concurrency: mutable global state

`nonisolated(unsafe)` on two stored statics:

- `SettingsStore.defaults` (`Sources/KaltoeCore/SettingsStore.swift`)
- `CookieVault.service` (`Sources/KaltoeCore/CookieVault.swift`, the
  `#if os(macOS)` branch)

Both are mutable **on purpose**: tests reassign `defaults` to a throwaway
`UserDefaults(suiteName:)` per test, and `service` to a sacrificial keychain
service. `nonisolated(unsafe)` states that contract honestly rather than
pretending the state is safe.

It is also an opt-out _from_ Swift 6 safety rather than a use of it, which is
why replacing both with real isolation is sub-project 3 and not folded in here.
Doing it properly reshapes injection across many existing tests and deserves its
own review cycle.

Note the computed statics (`SettingsStore.rules`, `WorkCalculator`'s helpers,
`HookRunner.hooksDirectory`, `FlexAPIConfig.userIdHash`, `LinuxPaths.configDirectory`,
`CookieVault.baseQuery`, `CookieVault.sessionFileURL`) need nothing — a computed
`static var` stores nothing and is not shared mutable state.

### Concurrency: `FlexClient: Sendable`

`Sources/KaltoeCore/FlexClient.swift`. Its only stored property is
`private let session: URLSession`, which is already `Sendable`, so the
conformance is free.

This single change fixes the same error in **two** places. Both `AppState` and
`HeadlessState` are `@MainActor` classes holding `private let client = FlexClient()`
and awaiting its nonisolated `fetchWeek`, which Swift 6 reports as
`sending 'self.client' risks causing data races`. Making the client `Sendable`
resolves both; annotating the two call sites would not.

### Concurrency: the notification delegate

`Sources/FlexTimer/SessionNotifier.swift`. `NotificationClickDelegate.shared` is
a `static let` of a non-`Sendable` class with a mutable `var onClick`.

The fix is `@preconcurrency` on the conformance:

```swift
final class NotificationClickDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
```

Marking the class `@MainActor` **alone does not work** — verified: it then fails
with `conformance of 'NotificationClickDelegate' to protocol
'UNUserNotificationCenterDelegate' crosses into main actor-isolated code`.
`@preconcurrency` on the conformance is the idiomatic answer for a delegate
protocol that is not yet isolation-annotated.

### Concurrency: `Sendable` on public value types

Ten types, all in `KaltoeCore`:

`Urgency`, `MenuDisplay`, `DisplayState`, `StoredCookie`, `ParseResult`,
`StatusLine`, `WorkRules`, `WorkRecord`, `WeekData`, `MenuLabelStyle`.

All are value types whose members are already `Sendable`, so each conformance is
free. They need it explicitly because **public types do not get implicit
`Sendable` inference across module boundaries** — which is why `Sources` built
clean while the test targets failed.

**Do not annotate the caseless namespace enums** — `CookieVault`,
`SettingsStore`, `WorkCalculator`, `Formatting`, `FlexAPIConfig`. They have no
instances, so `Sendable` on them is meaningless noise.

### Delete the availability fork

`Sources/FlexTimer/MenuBarView.swift`. The `if #available(macOS 14.0, *)` split
around `.accessibilityAddTraits(.isToggle)` collapses to an unconditional call,
and the `@ViewBuilder` helper that existed only to avoid `AnyView` across that
fork goes with it. This is the **only** availability fork in the codebase.

It also resolves a standing follow-up: `.accessibilityRepresentation { Toggle(...) }`
was queued solely to give macOS 13 a true switch role. With a macOS 26 floor the
`.isToggle` path is unconditional and that workaround is moot.

### `scripts/bundle.sh`

`LSMinimumSystemVersion` `13.0` → `26.0`.

## The Linux gap

**`swift test` passing green does not mean this migration is done.**

`CookieVault` is split `#if os(macOS)` / `#else`. The Linux branch declares its
own `public static var sessionFileOverride: URL?`, which the macOS compiler never
compiles — so it cannot appear in a macOS error set. It is mutable global state
and will need the same `nonisolated(unsafe)` treatment, and there may be more
Linux-only errors that only the Linux compiler can reveal.

`./scripts/build-linux.sh` (Docker, `swift:6.1-noble`) is therefore a **required**
verification step, not optional. At the time of writing the Docker daemon is not
running, so implementation cannot be completed until it is started.

## Error handling

No new failure paths. Every change is a build-configuration edit, an isolation
annotation, or a protocol conformance. No control flow moves.

## Testing

**No new tests.** This change has no behavioural surface: it alters how the
compiler checks the code, not what the code does. The evidence is that all 136
existing tests pass unmodified under the Swift 6 language mode, which was
demonstrated end to end before this spec was written.

A test asserting "the package uses tools version 6.0" would test the manifest
against itself and prove nothing.

## Verification

1. `swift build` — zero errors, zero warnings.
2. `swift test` — **136 tests, 0 failures**, unchanged from the current
   baseline. Any change in that number means behaviour moved and the migration
   overreached.
3. `./scripts/build-linux.sh` — must succeed. Baseline before this change:
   succeeds, with one pre-existing warning (`CookieVault.swift:110`, unused
   result of `createFile`) plus linker noise from `libFoundationEssentials`.
   Neither is ours; anything new is.
4. **The Linux test suite, which `build-linux.sh` does not run.** The script
   builds only the `kaltoe-core` product, so it would not compile the test
   targets — and the test targets are exactly where the
   `Sendable`-across-module-boundary errors surfaced on macOS. The Linux
   `CookieVault` branch and its `#if !os(macOS)` tests can only be checked this
   way:

   ```bash
   docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
     -e TZ=Asia/Seoul swift:6.1-noble swift test --scratch-path .build-linux
   ```

   `-e TZ=Asia/Seoul` is required, not optional: the repo documents that 13
   tests are date-shifted under the container's default UTC. Omitting it
   produces failures that look like migration damage and are not.

   Expect at least one Linux-only `nonisolated(unsafe)` here — the Linux
   `CookieVault` branch's `sessionFileOverride` — plus whatever else the Linux
   compiler reports.
5. `./scripts/bundle.sh` — must succeed, and the built `Info.plist` must carry
   `LSMinimumSystemVersion` 26.0.

The app is not launched as part of verification: it is in daily use, and
`AppState.start()` attaches `HookRunner`, so a second instance would fire the
user's clock-in/out hook scripts against their live workday.

## Queued follow-ups

Deliberately out of scope here; each needs sub-project 1 landed first.

2. **Typed throws.** `FlexClient.fetchWeek` throws `FlexError` but is declared
   bare `throws`. `throws(FlexError)` would let `AppState.refresh()` and
   `HeadlessState.refresh()` replace
   `catch let e as FlexClient.FlexError where e == .noSession || e == .sessionExpired`
   with a plain exhaustive `catch`. Small and contained.
3. **Replace both `nonisolated(unsafe)` hatches with real isolation.** The
   principled version of this spec's compromise. Reshapes how tests inject a
   `UserDefaults` suite and a keychain service, so it touches many test files.
4. **`defaultIsolation: MainActor`.** Requires tools version 6.2 and a Linux
   Docker image newer than `swift:6.1-noble`. **Must apply to the `FlexTimer`
   target only** — `KaltoeCore` has 29 `public static func`s of pure
   computation, `WorkCalculator` alone holding 12, and `KaltoeCoreTests` are
   deliberately not `@MainActor`. Isolating that module to the main actor would
   break every one of those call sites and is wrong for a platform-agnostic
   library that also builds for Linux.
