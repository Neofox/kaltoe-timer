# Session-Expiry Notification — Design

**Date**: 2026-07-10
**Status**: Approved

## Overview

When the Flex session dies, the menu bar quietly shows `—` and tracking stops; users may not notice for days and their weekly overtime silently drifts. Post one macOS user notification on session expiry so the user signs back in promptly.

## Goals

- Notify exactly once per expiry when `hasSession` transitions true → false.
- Clicking the notification opens the sign-in window.
- Zero behavior change for users who deny notification permission.

## Non-Goals

- No notification for other conditions (network failures, sync errors) — `refresh()` only clears `hasSession` on `FlexError.noSession`/`.sessionExpired`, never on network errors, so the trigger is already precise.
- No repeat/nag scheduling. One notification per expiry; re-arms after a successful sign-in.
- No notification settings or copy customization.

## Behavior

- Trigger: `hasSession` observed true → false (the expiry transition). Not fired when the app launches already signed out (nothing "expired" during use; the user just launched it).
- Copy: title `칼퇴타이머`, body `Flex session expired — sign in again to keep tracking.`
- Click action: bring the app forward and open the sign-in window (`AppState.signIn()`).
- Re-arm: after `hasSession` returns to true (successful sign-in / recovery), the next expiry notifies again.
- Permission: requested once on first attach (`.alert` only). Denied → all calls are silent no-ops.

## Implementation

- **New file** `Sources/FlexTimer/SessionNotifier.swift` (~50 lines):
    - `func sessionBecame(_ hasSession: Bool)` — tracks previous value, posts on true→false, re-arms on false→true. First call establishes the baseline without notifying.
    - Wraps `UNUserNotificationCenter` behind an injected closure (`post: (String, String) -> Void` style) so transition/re-arm logic is unit-testable without the notification framework. The default implementation requests authorization lazily and posts.
    - Acts as `UNUserNotificationCenterDelegate` for the click → `signIn` callback (callback injected, not a hard AppState dependency).
- **Attachment**: `AppState.start()` creates it (like `hookRunner`); property `var sessionNotifier: SessionNotifier?` stays nil in unit tests. This is required, not just hygiene: `UNUserNotificationCenter.current()` crashes in unbundled contexts (`swift test`, `swift run`), so the default poster must also guard `Bundle.main.bundleIdentifier != nil`.
- **Call sites**: `refresh()` and `signIn`'s completion already set `hasSession`; a `didSet` on `hasSession` calling `sessionNotifier?.sessionBecame(hasSession)` covers all of them.

## Testing

Unit tests for `SessionNotifier` with a spy poster:

- true→false posts exactly once; repeated false stays silent.
- false→true→false posts again (re-arm).
- First observed value (true or false) never posts.
- Click callback fires the injected sign-in closure.

The `UNUserNotificationCenter` wrapper itself is thin and not unit-tested; verified by a manual smoke test (bundled app, revoke session, observe notification).

## README

One paragraph under Authentication: the app notifies when the session expires; approve the notification permission prompt on first launch to get it.
