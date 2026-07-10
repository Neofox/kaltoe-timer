# macOS Auto-Start (Login Item) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 칼퇴타이머 on macOS registers itself as a login item on launch, removing the manual Login Items step.

**Architecture:** One guarded `SMAppService.mainApp.register()` call in the existing `AppDelegate`, mirroring the `SessionNotifier.live` .app-bundle guard. No UI, no settings, no core-library changes.

**Tech Stack:** Swift, ServiceManagement (`SMAppService`, macOS 13+ — already the platform floor).

**Spec:** `docs/superpowers/specs/2026-07-10-login-item-design.md`

## Global Constraints

- macOS shell only — `Sources/KaltoeCore`, `Sources/KaltoeDaemon`, and everything under `linux/` are untouched.
- The app must never override a user who disabled it in System Settings: swallow `register()` errors, and only attempt when `status != .enabled`.
- No login-item registration from `swift run`/tests: guard `Bundle.main.bundleURL.pathExtension == "app"`.
- `swift test` (118) must pass unchanged; there is no unit-test seam for `SMAppService` — verification is behavioral (launch the bundle, check System Settings → Login Items).

---

### Task 1: Auto-register login item + docs

**Files:**

- Modify: `Sources/FlexTimer/AppDelegate.swift` (whole file shown below)
- Modify: `README.md:43-46` (the "Add to Login Items:" block)
- Modify: `scripts/bundle.sh:44` (final echo line)
- Modify: `build/설치가이드-INSTALL-GUIDE.md:26` (untracked share guide — edit but do NOT git add)

**Interfaces:**

- Consumes: nothing new; `AppDelegate` is already wired via `@NSApplicationDelegateAdaptor` in `FlexTimerApp`.
- Produces: nothing consumed by other code.

- [ ] **Step 1: Rewrite AppDelegate.swift**

Replace the file's contents with:

```swift
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        registerAsLoginItem()
    }

    /// Adds the app to Login Items on launch so it starts automatically.
    /// Only from a real .app bundle — `swift run`/tests must not register a
    /// debug binary. Errors are deliberately swallowed: once a user disables
    /// the item in System Settings, macOS rejects register() and their
    /// choice must stand.
    private func registerAsLoginItem() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }
}
```

- [ ] **Step 2: Build and test**

Run: `swift build && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds; `Executed 118 tests, with 0 failures`.

- [ ] **Step 3: Update README**

In `README.md`, replace the block

```markdown
Add to Login Items:

1. System Settings → General → Login Items
2. Click the + icon
3. Select `/Applications/칼퇴타이머.app`
```

with

```markdown
The app adds itself to Login Items on first launch (you'll see a one-time
macOS notice). To stop it starting automatically, turn it off under System
Settings → General → Login Items — the app respects that and won't re-add
itself.
```

- [ ] **Step 4: Update bundle.sh echo**

In `scripts/bundle.sh`, change the final line

```bash
echo "Built $APP — copy to /Applications and add to Login Items."
```

to

```bash
echo "Built $APP — copy to /Applications (adds itself to Login Items on first launch)."
```

- [ ] **Step 5: Update the share guide (untracked)**

In `build/설치가이드-INSTALL-GUIDE.md`, replace item 6 of the macOS list

```markdown
6. Optional but recommended: System Settings → General → Login Items →
   add 칼퇴타이머 so it starts automatically.
```

with

```markdown
6. It adds itself to Login Items automatically on first launch (macOS shows
   a one-time notice) — nothing to do. Turn it off in System Settings →
   General → Login Items if you don't want that.
```

Do NOT `git add` this file — `build/` is gitignored.

- [ ] **Step 6: Behavioral verification**

Run: `./scripts/bundle.sh`
Expected: `Signed with kaltoe-dev …` and the new echo text.

Then (requires the human's machine/GUI — if running unattended, note it in the report and leave for the user): launch `build/칼퇴타이머.app` and check System Settings → General → Login Items shows 칼퇴타이머 under "Open at Login". `sfltool dumpbtm | grep -A3 -i kaltoe` can confirm registration from the terminal (may need sudo — skip if unattended).

- [ ] **Step 7: Commit**

```bash
git add Sources/FlexTimer/AppDelegate.swift README.md scripts/bundle.sh
git commit -m "feat: register as login item on launch (SMAppService)"
```
