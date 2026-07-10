# macOS Auto-Start (Login Item) — Design

2026-07-10

## Goal

칼퇴타이머 on macOS registers itself as a login item on launch, so coworkers
don't have to add it to Login Items manually. (Linux already autostarts via
the `.desktop` entry `install.sh` writes.)

## Design

In `Sources/FlexTimer/AppDelegate.swift`, `applicationDidFinishLaunching`
(after the existing activation-policy line):

- Guard `Bundle.main.bundleURL.pathExtension == "app"` — same pattern as
  `SessionNotifier.live`, so `swift run`/tests never register a stray login
  item pointing at a debug binary.
- If `SMAppService.mainApp.status != .enabled`, call
  `try? SMAppService.mainApp.register()`.
- Errors are deliberately swallowed: the meaningful failure is "user
  disabled it in System Settings," and macOS refusing `register()` there is
  exactly the behavior we want — the app never overrides the user's choice.
- Add `import ServiceManagement`. `SMAppService` requires macOS 13, which is
  already the platform floor.

No UI, no settings, no core-library changes.

## Behavior notes

- First launch: the app appears under System Settings → General → Login
  Items ("Open at Login"); macOS shows its standard one-time "added as
  Login Item" notice.
- The login item points at the bundle's current path; launching from the
  final location (/Applications, per install guide) registers the right
  path, and re-launching after a move self-heals it.

## Testing

The macOS shell has no unit-test seam for `SMAppService` (system service);
verification is behavioral: build via `scripts/bundle.sh`, launch the app,
confirm it appears in Login Items, and confirm `swift test` (118) still
passes untouched.

## Docs

- README: replace the "add to Login Items" instruction with a note that the
  app registers itself (and how to turn it off in System Settings).
- `build/설치가이드-INSTALL-GUIDE.md` (untracked share guide): same change —
  drop the manual Login Items step.
