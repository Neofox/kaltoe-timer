# Session-Expiry Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Post one macOS notification when the Flex session expires (`hasSession` true→false), re-arming after sign-in; clicking it opens the sign-in window.

**Architecture:** New `SessionNotifier` class holds the edge-detection/re-arm logic with an injected `post` closure (unit-testable, no notification framework). A `live` factory wires the real `UNUserNotificationCenter` poster and click→sign-in delegate, bundle-guarded because `UNUserNotificationCenter` crashes outside a real `.app` bundle. Attached in `AppState.start()` only (same pattern as `hookRunner`), driven by a `didSet` on `hasSession`.

**Tech Stack:** Swift Package Manager, XCTest, UserNotifications framework (system, no new dependency).

**Spec:** `docs/superpowers/specs/2026-07-10-session-expiry-notification-design.md`

## Global Constraints

- Notification copy exactly: title `칼퇴타이머`, body `Flex session expired — sign in again to keep tracking.`
- Fires only on an observed true→false transition; the first observed value is a baseline and never notifies; false→true re-arms.
- `AppState.sessionNotifier` stays nil until `start()` — unit tests must never touch `UNUserNotificationCenter` (it crashes under `swift test`).
- Authorization: request `.alert` once, in the live factory; denial → silent no-op behavior.
- No settings, no new dependencies.
- Test style: existing conventions (per-test UserDefaults suites not needed here; `@MainActor` on AppState tests).
- `swift test` full suite must pass at every commit. CAUTION: on this Mac an unattended plain `swift test` can hang >5 min on a securityd keychain-consent prompt; if it does, kill it and run under a temporary keychain (create one, `security list-keychains -s` it to the front after capturing the original list, restore the original list afterward and verify login.keychain-db + System.keychain are back).

---

### Task 1: SessionNotifier edge detection (TDD) + live factory

**Files:**

- Create: `Sources/FlexTimer/SessionNotifier.swift`
- Test: `Tests/FlexTimerTests/SessionNotifierTests.swift`

**Interfaces:**

- Consumes: nothing app-specific.
- Produces (Task 2 relies on these exact signatures):
    - `final class SessionNotifier` with `init(post: @escaping () -> Void)` and `func sessionBecame(_ hasSession: Bool)`
    - `@MainActor static func live(onNotificationClick: @escaping () -> Void) -> SessionNotifier`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlexTimerTests/SessionNotifierTests.swift`:

```swift
import XCTest
@testable import FlexTimer

final class SessionNotifierTests: XCTestCase {
    private var posted = 0
    private var notifier: SessionNotifier!

    override func setUp() {
        posted = 0
        notifier = SessionNotifier { [self] in posted += 1 }
    }

    func testFirstObservedValueIsBaselineAndNeverPosts() {
        notifier.sessionBecame(false)   // launch already signed out
        XCTAssertEqual(posted, 0)
        notifier.sessionBecame(true)    // baseline true either
        XCTAssertEqual(posted, 0)
    }

    func testExpiryTransitionPostsOnce() {
        notifier.sessionBecame(true)
        notifier.sessionBecame(false)
        XCTAssertEqual(posted, 1)
        notifier.sessionBecame(false)   // repeated false stays silent
        notifier.sessionBecame(false)
        XCTAssertEqual(posted, 1)
    }

    func testSignInReArmsForNextExpiry() {
        notifier.sessionBecame(true)
        notifier.sessionBecame(false)   // expiry 1
        notifier.sessionBecame(true)    // signed back in
        notifier.sessionBecame(false)   // expiry 2
        XCTAssertEqual(posted, 2)
    }

    func testLaunchSignedOutThenSignInThenExpiryPostsOnce() {
        notifier.sessionBecame(false)   // baseline: signed out at launch
        notifier.sessionBecame(true)    // signed in
        notifier.sessionBecame(false)   // expired
        XCTAssertEqual(posted, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --filter SessionNotifierTests`
Expected: build error — `cannot find 'SessionNotifier' in scope`

- [ ] **Step 3: Implement SessionNotifier**

Create `Sources/FlexTimer/SessionNotifier.swift`:

```swift
import Foundation
import UserNotifications

/// Posts one macOS notification when the Flex session expires (true→false
/// transition of `hasSession`), re-arming after a successful sign-in.
/// The poster is injected so the transition logic is testable; the real
/// poster comes from `live(onNotificationClick:)` and is only safe inside
/// a real .app bundle (attach in AppState.start(), like HookRunner).
final class SessionNotifier {
    private let post: () -> Void
    private var lastKnown: Bool?

    init(post: @escaping () -> Void) {
        self.post = post
    }

    func sessionBecame(_ hasSession: Bool) {
        defer { lastKnown = hasSession }
        guard let previous = lastKnown else { return }  // baseline: never notify
        if previous && !hasSession { post() }
    }

    /// Real UNUserNotificationCenter wiring. UNUserNotificationCenter.current()
    /// crashes outside a real .app bundle (swift test / swift run), hence the guard.
    @MainActor
    static func live(onNotificationClick: @escaping () -> Void) -> SessionNotifier {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return SessionNotifier(post: {})
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        NotificationClickDelegate.shared.onClick = onNotificationClick
        center.delegate = NotificationClickDelegate.shared
        return SessionNotifier(post: {
            let content = UNMutableNotificationContent()
            content.title = "칼퇴타이머"
            content.body = "Flex session expired — sign in again to keep tracking."
            center.add(UNNotificationRequest(identifier: "session-expired-\(UUID().uuidString)",
                                             content: content, trigger: nil))
        })
    }
}

/// Retained delegate for notification clicks (UNUserNotificationCenter holds
/// its delegate weakly).
final class NotificationClickDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationClickDelegate()
    var onClick: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        onClick?()
        completionHandler()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionNotifierTests`
Expected: 4 tests pass

Run: `swift test`
Expected: full suite passes

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/SessionNotifier.swift Tests/FlexTimerTests/SessionNotifierTests.swift
git commit -m "feat: SessionNotifier posts once per session expiry, re-arms on sign-in"
```

---

### Task 2: AppState wiring + README

**Files:**

- Modify: `Sources/FlexTimer/AppState.swift` (the `hasSession` property, `start()`)
- Modify: `README.md` (Authentication section)
- Test: `Tests/FlexTimerTests/AppStateTests.swift` (one new test)

**Interfaces:**

- Consumes: `SessionNotifier` from Task 1 — `init(post:)`, `sessionBecame(_:)`, `live(onNotificationClick:)`.
- Produces: `AppState.sessionNotifier: SessionNotifier?` — nil until `start()`.

- [ ] **Step 1: Write the failing wiring test**

Add to `Tests/FlexTimerTests/AppStateTests.swift`:

```swift
    func testSessionExpiryNotifiesViaAttachedNotifier() {
        let state = AppState()
        var posted = 0
        state.sessionNotifier = SessionNotifier { posted += 1 }
        state.sessionNotifier?.sessionBecame(state.hasSession)  // baseline, as start() does
        let wasSignedIn = state.hasSession
        state.hasSession = true      // ensure a true baseline regardless of Keychain state
        state.hasSession = false     // expiry
        XCTAssertEqual(posted, 1)
        state.hasSession = wasSignedIn  // restore for other tests' AppState instances
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppStateTests/testSessionExpiryNotifiesViaAttachedNotifier`
Expected: build error — `value of type 'AppState' has no member 'sessionNotifier'`

- [ ] **Step 3: Wire into AppState**

In `Sources/FlexTimer/AppState.swift`:

Replace the `hasSession` declaration (currently `@Published var hasSession: Bool = CookieVault.load()?.isEmpty == false`) with:

```swift
    @Published var hasSession: Bool = CookieVault.load()?.isEmpty == false {
        didSet { sessionNotifier?.sessionBecame(hasSession) }
    }
```

Next to `var hookRunner: HookRunner?`, add:

```swift
    /// Attached in start() only, so unit tests never touch UNUserNotificationCenter.
    var sessionNotifier: SessionNotifier?
```

In `start()`, next to `hookRunner = HookRunner()`, add:

```swift
        sessionNotifier = SessionNotifier.live { [weak self] in
            Task { @MainActor in self?.signIn() }
        }
        sessionNotifier?.sessionBecame(hasSession)  // establish baseline
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: full suite passes, including the new wiring test

- [ ] **Step 5: Update README**

In README.md's `## Authentication` section, append this bullet to the existing list:

```markdown
- **Expiry notification**: when the session expires, the app posts a macOS notification ("Flex session expired — sign in again to keep tracking."); clicking it opens the sign-in window. Approve the notification permission prompt on first launch to get it.
```

- [ ] **Step 6: Commit**

```bash
git add Sources/FlexTimer/AppState.swift Tests/FlexTimerTests/AppStateTests.swift README.md
git commit -m "feat: notify on Flex session expiry; click opens sign-in"
```
