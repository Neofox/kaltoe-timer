# High-Contrast Menu Bar Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in setting that renders the normal-state menu bar label as a non-template image so it stays readable on the menu bar of an inactive display.

**Architecture:** A pure `MenuLabelStyle.resolve(urgency:highContrast:)` in `KaltoeCore` decides between three renderings; `MenuBarLabel` in `FlexTimer` executes them. The two image-backed renderings (the existing urgency pill and the new solid label) share one `ImageRenderer` helper. The setting lives in `UserDefaults` via `SettingsStore` and is toggled live from the popover through an `AppState` `@Published` property.

**Tech Stack:** Swift 5.9, SwiftUI (`MenuBarExtra`, `ImageRenderer`), AppKit (`NSImage`, `NSFont`), XCTest, SwiftPM.

Spec: `docs/superpowers/specs/2026-07-29-high-contrast-menubar-design.md`

## Global Constraints

- Swift tools version 5.9; deployment target macOS 13. No new dependencies.
- `MenuLabelStyle` and the settings accessor go in `KaltoeCore`, which must stay
  free of AppKit and SwiftUI imports — it also builds for Linux. All rendering
  code stays in `Sources/FlexTimer`.
- UserDefaults key, verbatim: `highContrastOnInactiveDisplays`. Domain:
  `com.perso.flextimer`. Default: off.
- Urgency colour outranks the contrast preference: `.warning` and `.critical`
  must render their existing orange/red pill whether or not the setting is on.
- Toggle label copy, verbatim: `High contrast on other displays`
- Every rendered menu bar image must end with `image.isTemplate = false`. That
  single line is the entire mechanism — a template image is what macOS greys out
  on the inactive display.
- Run the full suite with `swift test` from the repo root. Build the installable
  bundle with `./scripts/bundle.sh`.

---

### Task 1: `MenuLabelStyle` resolver

The branch decision, as pure logic in `KaltoeCore` so it is testable without AppKit.

**Files:**

- Create: `Sources/KaltoeCore/MenuLabelStyle.swift`
- Test: `Tests/KaltoeCoreTests/MenuLabelStyleTests.swift`

**Interfaces:**

- Consumes: `Urgency` from `Sources/KaltoeCore/DisplayState.swift` (`public enum Urgency: String, Equatable { case normal, warning, critical }`).
- Produces: `public enum MenuLabelStyle: Equatable { case plain; case solid; case pill(Urgency) }` and `public static func resolve(urgency: Urgency, highContrast: Bool) -> MenuLabelStyle`. Task 3 switches on exactly these three cases.

- [ ] **Step 1: Write the failing test**

Create `Tests/KaltoeCoreTests/MenuLabelStyleTests.swift`:

```swift
import XCTest
@testable import KaltoeCore

final class MenuLabelStyleTests: XCTestCase {
    func testNormalIsPlainWhenHighContrastOff() {
        XCTAssertEqual(MenuLabelStyle.resolve(urgency: .normal, highContrast: false), .plain)
    }

    func testNormalIsSolidWhenHighContrastOn() {
        XCTAssertEqual(MenuLabelStyle.resolve(urgency: .normal, highContrast: true), .solid)
    }

    /// Urgency colour outranks the contrast preference — turning high contrast
    /// on must never swallow the orange/red alert.
    func testAlertingUrgenciesStayPillRegardlessOfHighContrast() {
        for highContrast in [false, true] {
            XCTAssertEqual(MenuLabelStyle.resolve(urgency: .warning, highContrast: highContrast),
                           .pill(.warning))
            XCTAssertEqual(MenuLabelStyle.resolve(urgency: .critical, highContrast: highContrast),
                           .pill(.critical))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MenuLabelStyleTests`
Expected: FAIL — compile error, `cannot find 'MenuLabelStyle' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/KaltoeCore/MenuLabelStyle.swift`:

```swift
import Foundation

/// How the menu bar label should be drawn.
///
/// `.plain` is a template view, which macOS greys out on the menu bar of a
/// display that does not hold the active window. `.solid` and `.pill` are
/// pre-rendered non-template images, which it leaves alone — that is the whole
/// point of the high-contrast setting.
public enum MenuLabelStyle: Equatable {
    /// Template icon + text. Default appearance.
    case plain
    /// Non-template icon + text in a solid, appearance-matched colour.
    case solid
    /// Non-template capsule for the alerting states.
    case pill(Urgency)

    /// Urgency wins over the contrast preference: an alerting state always
    /// keeps its coloured pill, so the setting can never suppress it.
    public static func resolve(urgency: Urgency, highContrast: Bool) -> MenuLabelStyle {
        switch urgency {
        case .warning, .critical: return .pill(urgency)
        case .normal: return highContrast ? .solid : .plain
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MenuLabelStyleTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/MenuLabelStyle.swift Tests/KaltoeCoreTests/MenuLabelStyleTests.swift
git commit -m "feat: MenuLabelStyle resolver for menu bar label rendering"
```

---

### Task 2: Persist the setting

**Files:**

- Modify: `Sources/KaltoeCore/SettingsStore.swift` (add after the `rules` property, before `key(for:)`)
- Test: `Tests/KaltoeCoreTests/SettingsStoreTests.swift` (append to the existing class)

**Interfaces:**

- Consumes: `SettingsStore.defaults` (`public static var defaults = UserDefaults.standard`), already in the file.
- Produces: `public static var highContrastOnInactiveDisplays: Bool { get set }`. Task 4's `AppState` reads and writes it.

Note: every other property in this file is read-only computed. This one needs a
setter because the popover toggle writes it — see the spec's rationale for why
`defaults write` alone is not enough.

- [ ] **Step 1: Write the failing test**

Append these two methods inside the existing `final class SettingsStoreTests` in
`Tests/KaltoeCoreTests/SettingsStoreTests.swift` (the existing `setUp` already
points `SettingsStore.defaults` at a fresh throwaway suite per test):

```swift
    func testHighContrastDefaultsToOff() {
        XCTAssertFalse(SettingsStore.highContrastOnInactiveDisplays)
    }

    func testHighContrastRoundTrips() {
        SettingsStore.highContrastOnInactiveDisplays = true
        XCTAssertTrue(SettingsStore.highContrastOnInactiveDisplays)
        XCTAssertTrue(SettingsStore.defaults.bool(forKey: "highContrastOnInactiveDisplays"))
        SettingsStore.highContrastOnInactiveDisplays = false
        XCTAssertFalse(SettingsStore.highContrastOnInactiveDisplays)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsStoreTests`
Expected: FAIL — compile error, `type 'SettingsStore' has no member 'highContrastOnInactiveDisplays'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/KaltoeCore/SettingsStore.swift`, add after the closing brace of the
`rules` computed property:

```swift
    /// Render the menu bar label as a non-template image so macOS cannot grey
    /// it out on the menu bar of an inactive display. Absent key reads false,
    /// so this is off by default with no registration needed.
    public static var highContrastOnInactiveDisplays: Bool {
        get { defaults.bool(forKey: "highContrastOnInactiveDisplays") }
        set { defaults.set(newValue, forKey: "highContrastOnInactiveDisplays") }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SettingsStoreTests`
Expected: PASS — all existing tests plus the 2 new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/KaltoeCore/SettingsStore.swift Tests/KaltoeCoreTests/SettingsStoreTests.swift
git commit -m "feat: highContrastOnInactiveDisplays setting"
```

---

### Task 3: Solid non-template rendering

Rewrites `MenuBarLabel` around the three styles and collapses the duplicated
`ImageRenderer` plumbing into one helper.

**Files:**

- Modify: `Sources/FlexTimer/MenuBarLabel.swift` (whole file — replace contents)
- Modify: `Sources/FlexTimer/FlexTimerApp.swift:19` (pass the new parameter)

**Interfaces:**

- Consumes: `MenuLabelStyle.resolve(urgency:highContrast:)` from Task 1; `MenuDisplay`, `DisplayState.iconName`, `Urgency` from `KaltoeCore`.
- Produces: `MenuBarLabel(display:text:highContrast:)` — a three-parameter initialiser. Task 4 supplies `highContrast` from `AppState`.

There is no unit test in this task. `ImageRenderer` and `NSScreen` are AppKit
surfaces, and the property that matters — legibility on a dimmed menu bar — is
only observable by eye. It is covered by the manual verification in Task 4.

The `extension Urgency { var pillColor: Color? }` at the bottom of the current
file is deleted: it existed only to drive the old `if let` branch, and the
optional return has no meaning now that `.pill(Urgency)` is only ever
constructed for the alerting cases.

- [ ] **Step 1: Replace `MenuBarLabel.swift`**

Replace the entire contents of `Sources/FlexTimer/MenuBarLabel.swift` with:

```swift
import AppKit
import SwiftUI
import KaltoeCore

/// Menu bar label. Normally a template icon+text view; for the alerting
/// urgencies, and for the whole label when high contrast is on, a pre-rendered
/// non-template NSImage.
///
/// Non-template is the entire mechanism. macOS greys out template images on the
/// menu bar of a display that does not hold the active window, and also ignores
/// colours on plain label views — rendering to pixels sidesteps both.
struct MenuBarLabel: View {
    let display: MenuDisplay
    let text: String
    let highContrast: Bool

    /// Resolves against the menu bar's appearance, so the solid fill opposes
    /// whatever the bar is drawn in.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch MenuLabelStyle.resolve(urgency: display.urgency, highContrast: highContrast) {
        case .pill(let urgency):
            MenuBarLabelImage(icon: display.state.iconName, text: text,
                              foreground: .white,
                              background: urgency == .critical ? .red : .orange,
                              font: .system(size: 12, weight: .medium))
        case .solid:
            MenuBarLabelImage(icon: display.state.iconName, text: text,
                              foreground: colorScheme == .dark ? .white : .black,
                              background: nil,
                              font: Font(NSFont.menuBarFont(ofSize: 0)))
        case .plain:
            HStack(spacing: 3) {
                Image(systemName: display.state.iconName)
                Text(text)
            }
        }
    }
}

/// Renders icon+text to a non-template NSImage, with an optional capsule behind
/// it. A nil background draws the glyphs alone at the menu bar's own metrics, so
/// toggling high contrast does not shift the label's width or position.
private struct MenuBarLabelImage: View {
    let icon: String
    let text: String
    let foreground: Color
    let background: Color?
    let font: Font

    var body: some View {
        Image(nsImage: renderedImage())
    }

    @MainActor private func renderedImage() -> NSImage {
        let content = HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(font)
        .foregroundStyle(foreground)
        .padding(.horizontal, background == nil ? 0 : 7)
        .padding(.vertical, background == nil ? 0 : 2)
        .background {
            if let background {
                Capsule().fill(background)
            }
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }
}
```

- [ ] **Step 2: Update the call site**

In `Sources/FlexTimer/FlexTimerApp.swift`, replace line 19:

```swift
            MenuBarLabel(display: state.menuDisplay, text: state.menuText)
```

with:

```swift
            MenuBarLabel(display: state.menuDisplay, text: state.menuText,
                         highContrast: SettingsStore.highContrastOnInactiveDisplays)
```

This reads the setting directly for now; Task 4 replaces it with the observable
`AppState` property so the popover toggle takes effect immediately.

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests pass. Nothing tests this file directly — you
are confirming the package still compiles and that Tasks 1–2 did not regress.

- [ ] **Step 4: Smoke-test the rendering**

```bash
defaults write com.perso.flextimer highContrastOnInactiveDisplays -bool true
./scripts/bundle.sh
```

Launch the bundled app. Confirm the label still shows the icon and countdown at
its usual size — you are checking the image path renders at all, not judging
contrast yet. Full verification is Task 4, once the toggle exists.

Then clear the key so Task 4 starts from the default:

```bash
defaults write com.perso.flextimer highContrastOnInactiveDisplays -bool false
```

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/MenuBarLabel.swift Sources/FlexTimer/FlexTimerApp.swift
git commit -m "feat: non-template solid rendering for the menu bar label"
```

---

### Task 4: Live toggle, docs, and verification

**Files:**

- Modify: `Sources/FlexTimer/AppState.swift` (add a `@Published` property alongside the existing ones)
- Modify: `Sources/FlexTimer/FlexTimerApp.swift:19-20` (source the flag from `AppState`)
- Modify: `Sources/FlexTimer/MenuBarView.swift` (add the toggle before the Quit button)
- Modify: `README.md` (document the defaults key)
- Test: `Tests/FlexTimerTests/AppStateTests.swift` (append to the existing class)

**Interfaces:**

- Consumes: `SettingsStore.highContrastOnInactiveDisplays` from Task 2; `MenuBarLabel(display:text:highContrast:)` from Task 3.
- Produces: `AppState.highContrastOnInactiveDisplays: Bool` — a `@Published` property that writes through to `SettingsStore` on set.

- [ ] **Step 1: Write the failing test**

Append this method inside the existing `@MainActor final class AppStateTests` in
`Tests/FlexTimerTests/AppStateTests.swift`:

```swift
    func testHighContrastToggleWritesThroughToSettings() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        XCTAssertFalse(state.highContrastOnInactiveDisplays)

        state.highContrastOnInactiveDisplays = true
        XCTAssertTrue(SettingsStore.highContrastOnInactiveDisplays)

        state.highContrastOnInactiveDisplays = false
        XCTAssertFalse(SettingsStore.highContrastOnInactiveDisplays)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testHighContrastToggleWritesThroughToSettings`
Expected: FAIL — compile error, `value of type 'AppState' has no member 'highContrastOnInactiveDisplays'`.

- [ ] **Step 3: Add the property to `AppState`**

In `Sources/FlexTimer/AppState.swift`, add after the `hasSession` property (the
last of the `@Published` block, ending at line 17):

```swift
    /// Mirrors the stored setting. Written through on set so the popover toggle
    /// persists, and published so the menu bar label re-renders immediately —
    /// an external `defaults write` would not be picked up by the running app.
    @Published var highContrastOnInactiveDisplays = SettingsStore.highContrastOnInactiveDisplays {
        didSet { SettingsStore.highContrastOnInactiveDisplays = highContrastOnInactiveDisplays }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter testHighContrastToggleWritesThroughToSettings`
Expected: PASS.

- [ ] **Step 5: Source the label's flag from `AppState`**

In `Sources/FlexTimer/FlexTimerApp.swift`, replace the label call added in
Task 3:

```swift
            MenuBarLabel(display: state.menuDisplay, text: state.menuText,
                         highContrast: SettingsStore.highContrastOnInactiveDisplays)
```

with:

```swift
            MenuBarLabel(display: state.menuDisplay, text: state.menuText,
                         highContrast: state.highContrastOnInactiveDisplays)
```

If `import KaltoeCore` is now unused in this file, leave it — `MenuDisplay` and
`DisplayState` still come from there via `AppState`'s types.

- [ ] **Step 6: Add the popover toggle**

In `Sources/FlexTimer/MenuBarView.swift`, in the block starting at line 55, add
the toggle between the sign-in/refresh button and the Quit button so the section
reads:

```swift
            Divider()
            if state.hasSession {
                Button("↻ Refresh from Flex") { Task { await state.refresh() } }
            } else {
                Button("Sign in to Flex…") { state.signIn() }
            }
            Toggle("High contrast on other displays",
                   isOn: $state.highContrastOnInactiveDisplays)
                .toggleStyle(.checkbox)
            Button("Quit") { NSApp.terminate(nil) }
```

- [ ] **Step 7: Build and run the full suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 8: Document the setting**

In `README.md`, inside the ```bash block under `## Customizing Work Hours` that
currently ends with the `familyDayDeductionHours` line (around line 93), append:

```bash
# Keep the menu bar icon and time readable on the menu bar of an inactive
# display, by rendering them at full contrast instead of as a dimmable template
# image (default: false). Also toggleable from the menu popover.
defaults write com.perso.flextimer highContrastOnInactiveDisplays -bool true
```

- [ ] **Step 9: Verify by eye on two displays**

```bash
./scripts/bundle.sh
```

Launch the bundled app with a second display attached and work through the
spec's verification list:

1. Toggle **off**, focus a window on display A — the label on display B is
   dimmed. This is the bug being fixed.
2. Toggle **on** from the popover — the label on display B is now legible, and
   the label on display A has not changed width or position.
3. Switch System Settings → Appearance between Light and Dark — the glyphs
   invert and stay legible in both. **This is the step that catches the known
   risk**: if `@Environment(\.colorScheme)` tracks the app's appearance rather
   than the menu bar's, you will see black glyphs on a dark bar (most likely in
   Light Mode with a dark wallpaper). If that happens, stop and report it — the
   fallback is reading `effectiveAppearance` off the status item button, which
   the spec deliberately left unbuilt.
4. Force an alerting state — set a manual start time in the popover such that
   fewer than 30 minutes remain, then fewer than 10 — and confirm the orange and
   red pills still appear with the toggle **on**.

- [ ] **Step 10: Commit**

```bash
git add Sources/FlexTimer/AppState.swift Sources/FlexTimer/FlexTimerApp.swift \
        Sources/FlexTimer/MenuBarView.swift Tests/FlexTimerTests/AppStateTests.swift \
        README.md
git commit -m "feat: popover toggle for high-contrast menu bar label"
```
