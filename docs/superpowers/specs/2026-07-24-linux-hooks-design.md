# Linux Hook Support — Design

**Date**: 2026-07-24
**Status**: Approved

## Overview

Enable the existing clock-in/clock-out hook scripts (see
`2026-07-09-clock-hooks-design.md`) on the Linux build. `HookRunner` already
lives in cross-platform `KaltoeCore` but only the macOS app wires it in; the
Linux daemon (`KaltoeDaemon`) never fires hooks. The linux-build design listed
hooks as out of scope for v1 — this closes that gap.

Guiding constraint (user requirement): **smallest possible diff, macOS
behavior byte-identical.**

## Decision Record

Two approaches were considered for the once-per-day dedupe state on Linux:

- **A — file-backed store**: abstract `HookRunner`'s `UserDefaults` dependency
  behind a key-value seam; Linux persists a JSON dict at
  `~/.config/kaltoe-timer/hook-state.json`. More code (~30 lines), state lives
  with the rest of the Linux config.
- **B — keep `UserDefaults`, add `synchronize()`** _(chosen)_: verified
  empirically in the release toolchain image (`swift:6.1-noble`):
    - Bare `set()` never persists on Linux — nothing is written to disk, even
      on clean exit. Unfixed, hooks would re-fire on every daemon restart.
    - `defaults.synchronize()` flushes immediately and survives SIGKILL
      (the tray stops the core with SIGTERM-then-SIGKILL).
    - State lands at `$HOME/.config/<executable-name>.plist`, i.e.
      `~/.config/kaltoe-core.plist`, keyed by binary name.

B was chosen for the smaller diff. Known trade-offs, accepted: the state file
location is a swift-corelibs-foundation implementation detail outside
`~/.config/kaltoe-timer/`; it is keyed to the executable name (renaming the
binary orphans the state — worst case, hooks fire a second time that day); it
does not honor the `KALTOE_CONFIG_DIR` override.

## Changes

### 1. `Sources/KaltoeCore/HookRunner.swift`

- `hooksDirectory` becomes platform-split:
    - macOS: `~/Library/Application Support/칼퇴타이머/hooks/` (unchanged).
    - Linux: `<config dir>/hooks/`, where the config dir is
      `$KALTOE_CONFIG_DIR` if set, else `~/.config/kaltoe-timer` — the same
      resolution `CookieVault` uses.
- `markFiredIfNeeded` adds, immediately after `defaults.set(true, forKey:)`:

    ```swift
    #if !os(macOS)
    defaults.synchronize()
    #endif
    ```

### 2. Shared config-dir helper

The `KALTOE_CONFIG_DIR`-or-`~/.config/kaltoe-timer` lookup currently inlined
in `CookieVault.sessionFileURL` moves to a tiny internal helper so hooks and
session state can't drift:

```swift
#if !os(macOS)
enum LinuxPaths {
    /// $KALTOE_CONFIG_DIR if set, else ~/.config/kaltoe-timer.
    static var configDirectory: URL {
        ProcessInfo.processInfo.environment["KALTOE_CONFIG_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/kaltoe-timer", isDirectory: true)
    }
}
#endif
```

`CookieVault.sessionFileURL` is edited only to call the helper. The
`sessionFileOverride` test seam is untouched.

### 3. `Sources/KaltoeDaemon/main.swift`

Mirror the macOS call site exactly (`AppState.recompute` calls
`hookRunner.evaluate(today:now:)` once per tick, no session gate):

- Create one `HookRunner()` before the daemon loop.
- Each 1-second iteration:
  `hookRunner.evaluate(today: state.weekData.todayRecord(now: now), now: now)`.

No changes to `HeadlessState`.

### 4. Tests (`Tests/KaltoeCoreTests/HookRunnerTests.swift`)

- The two assertions hard-coding the macOS suffix
  (`칼퇴타이머/hooks/on-clock-in`, `.../on-clock-out`) get a
  platform-conditional expected suffix (`kaltoe-timer/hooks/...` on Linux) so
  the suite passes in the Linux Docker run (`-e TZ=Asia/Seoul`, per
  `scripts/build-linux.sh`).
- One new Linux-only test: `hooksDirectory` honors `KALTOE_CONFIG_DIR`.
- All other tests unchanged — the dedupe logic is untouched.

### 5. `linux/README-linux.md`

New "Hooks" section:

- Directory: `~/.config/kaltoe-timer/hooks/` with optional executables
  `on-clock-in` / `on-clock-out`; `chmod +x`; missing or non-executable →
  silently skipped.
- Same env vars as macOS: `KALTOE_EVENT`, `KALTOE_CLOCK_IN`,
  `KALTOE_CLOCK_OUT` (ISO8601).
- Ubuntu-appropriate examples with `#!/bin/bash`:
  `systemd-inhibit --what=idle sleep infinity &` (keep-awake, pidfile pattern)
  and `loginctl lock-session` (lock on clock-out).
- Linux-specific behavior notes:
    - Clock-**in** detection is also Flex-sync-only on Linux (no manual
      start-entry UI), so both hooks can lag up to ~10 minutes.
    - Same once-per-event-per-day semantics as macOS, including
      fire-on-late-detection and the midnight-rollover caveat.
- Uninstall section adds `~/.config/kaltoe-core.plist`.

## Release

Re-run `scripts/build-linux.sh`, distribute the new tarball; users re-run
`install.sh`. User hook scripts survive upgrades (they live under
`~/.config`, which install/uninstall of `~/.local/share/kaltoe-timer` never
touches — though the documented uninstall command removes
`~/.config/kaltoe-timer` and therefore the hooks).

## Out of Scope

- No new events, no output capture, no process management — identical
  fire-and-forget semantics to macOS.
- No change to how the tray or daemon are launched.
