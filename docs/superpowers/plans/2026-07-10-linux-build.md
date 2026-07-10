# 칼퇴타이머 Linux (Ubuntu) Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Linux build of 칼퇴타이머 — a tray icon + embedded Flex login for Ubuntu — by splitting the SwiftPM package into a portable `KaltoeCore` library, a headless `kaltoe-core` daemon, and a Python/GTK tray frontend.

**Architecture:** Three SwiftPM targets: `KaltoeCore` (all business logic, cross-platform), `FlexTimer` (existing macOS shell, unchanged behavior, only compiled on macOS), and `KaltoeDaemon` → product `kaltoe-core` (headless loop emitting NDJSON status lines). On Linux, `linux/kaltoe-tray.py` spawns `kaltoe-core`, renders its output in an AyatanaAppIndicator tray item, and hosts a WebKitGTK login window that writes `~/.config/kaltoe-timer/session.json`.

**Tech Stack:** Swift 5.9+ (SwiftPM, Foundation/FoundationNetworking), Python 3 + PyGObject (GTK 3, AyatanaAppIndicator3 0.1, WebKit2 4.1), Docker (`swift:6.1-noble`) for the Linux build.

**Spec:** `docs/superpowers/specs/2026-07-10-linux-build-design.md`

## Global Constraints

- **Naming:** all NEW artifacts use kaltoe naming (`KaltoeCore`, `KaltoeDaemon`, `kaltoe-core`, `kaltoe-tray.py`, `~/.config/kaltoe-timer/`). Do NOT rename the existing `FlexTimer` module, the bundle id `com.perso.flextimer`, or the Keychain service `com.perso.flextimer.session`.
- Files named after the flex.team service (`FlexClient.swift`, `FlexAPIConfig.swift`, `FlexRecordParser.swift`) keep their names.
- **session.json format** (Linux, written by Python, read by Swift): `{"userIdHash": "<string>", "cookies": [{"name","value","domain","path","expires"}]}` where `expires` is **Unix epoch seconds (number) or null**. Swift side uses `.secondsSince1970` date coding for this file.
- **NDJSON status line format** (daemon stdout → tray): keys `text`, `icon`, `urgency`, `hasSession`, `lastSync` (ISO8601, optional), `syncError` (optional). Encoder uses `.sortedKeys` + `.iso8601`. Optionals are OMITTED when nil (JSONEncoder default), so the Python side must use `.get()`.
- No new SwiftPM dependencies. No pip dependencies (system PyGObject only).
- `swift test` on macOS must pass after every task (`swift test` runs plainly — the sacrificial-keychain fix means no temp-keychain workaround).
- Shipped Linux binary targets **x86_64** (`docker run --platform linux/amd64`).
- Deferred (do NOT build): Linux UI for manual start-time entry, Linux hook-script execution, libsecret storage.

---

### Task 1: Split the package into KaltoeCore + macOS-only shell

Pure refactor: move portable files into a library target, add `public`, keep every existing test green. No behavior change.

**Files:**

- Modify: `Package.swift`
- Move (git mv): `Sources/FlexTimer/{WorkCalculator,FlexRecordParser,DisplayState,Formatting,FlexAPIConfig,FlexClient,SettingsStore,HookRunner,CookieVault}.swift` → `Sources/KaltoeCore/`
- Move (git mv): `Tests/FlexTimerTests/{WorkCalculatorTests,FormattingTests,FlexClientTests,CookieVaultTests,SettingsStoreTests,HookRunnerTests,SmokeTests}.swift` and `Tests/FlexTimerTests/Fixtures/` → `Tests/KaltoeCoreTests/`
- Modify: remaining mac shell sources (`AppState.swift`, `MenuBarLabel.swift`, `MenuBarView.swift`, `LoginWindowController.swift`, `FlexTimerApp.swift`) and remaining mac tests (`AppStateTests.swift`, `LoginWindowTests.swift`, `SessionNotifierTests.swift`)

**Interfaces:**

- Produces: module `KaltoeCore` exporting (all `public`): `WorkRules`, `WorkRecord` (+ `public init(clockIn:clockOut:flexWorkedNet:)`), `WorkCalculator` (all static funcs), `DisplayState` (+ `menuBarText`, `iconName`, `computeDisplay`, `compute`), `MenuDisplay` (+ `public init(state:urgency:)`), `Urgency` as `public enum Urgency: String` (rawValue needed by Task 3), `Formatting`, `FlexClient` (+ `public init()`, `fetchWeek`, `FlexError`), `ParseResult` (public properties, internal init is fine), `FlexAPIConfig` (`loginURL`, `sessionCookieNames`, `userIdHash`), `CookieVault` (+ `StoredCookie` with both public inits, `service`, `defaultService`, `save`, `saveStored`, `load`, `clear`), `SettingsStore` (`defaults`, `rules`, `manualStart`, `setManualStart`), `HookRunner` (+ `public init(defaults:execute:)`, `evaluate`, `hooksDirectory`, `launchDetached` must become `public` because it's a default argument of a public init).
- `FlexRecordParser` stays internal (tests use `@testable`).

**Steps:**

- [ ] **Step 1: Move the files**

```bash
mkdir -p Sources/KaltoeCore Tests/KaltoeCoreTests
git mv Sources/FlexTimer/WorkCalculator.swift Sources/FlexTimer/FlexRecordParser.swift \
       Sources/FlexTimer/DisplayState.swift Sources/FlexTimer/Formatting.swift \
       Sources/FlexTimer/FlexAPIConfig.swift Sources/FlexTimer/FlexClient.swift \
       Sources/FlexTimer/SettingsStore.swift Sources/FlexTimer/HookRunner.swift \
       Sources/FlexTimer/CookieVault.swift Sources/KaltoeCore/
git mv Tests/FlexTimerTests/WorkCalculatorTests.swift Tests/FlexTimerTests/FormattingTests.swift \
       Tests/FlexTimerTests/FlexClientTests.swift Tests/FlexTimerTests/CookieVaultTests.swift \
       Tests/FlexTimerTests/SettingsStoreTests.swift Tests/FlexTimerTests/HookRunnerTests.swift \
       Tests/FlexTimerTests/SmokeTests.swift Tests/FlexTimerTests/Fixtures Tests/KaltoeCoreTests/
```

- [ ] **Step 2: Rewrite Package.swift**

The macOS targets are excluded on Linux at manifest-evaluation time (`#if os(macOS)` runs on the build host), so `swift build`/`swift test` inside Docker never see AppKit code.

```swift
// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .executable(name: "kaltoe-core", targets: ["KaltoeDaemon"]),
]
var targets: [Target] = [
    .target(name: "KaltoeCore", path: "Sources/KaltoeCore"),
    .executableTarget(name: "KaltoeDaemon", dependencies: ["KaltoeCore"], path: "Sources/KaltoeDaemon"),
    .testTarget(name: "KaltoeCoreTests", dependencies: ["KaltoeCore"], path: "Tests/KaltoeCoreTests",
                resources: [.copy("Fixtures")]),
]
#if os(macOS)
products.append(.executable(name: "FlexTimer", targets: ["FlexTimer"]))
targets += [
    .executableTarget(name: "FlexTimer", dependencies: ["KaltoeCore"], path: "Sources/FlexTimer"),
    .testTarget(name: "FlexTimerTests", dependencies: ["FlexTimer"], path: "Tests/FlexTimerTests"),
]
#endif

let package = Package(
    name: "FlexTimer",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
```

Note: `KaltoeDaemon` needs a placeholder to compile; create it now:

```bash
mkdir -p Sources/KaltoeDaemon
printf '// kaltoe-core daemon — implemented in a later task.\nprint("kaltoe-core: not yet implemented")\n' > Sources/KaltoeDaemon/main.swift
```

- [ ] **Step 3: Add `public` to the KaltoeCore API and fix imports**

In `Sources/KaltoeCore/`: mark the declarations listed in **Interfaces** above `public` (types, their used members, and static funcs). Concretely:

- `WorkRules`: `public struct`, all stored properties `public var`, add `public init() {}`.
- `WorkRecord`: `public struct`, properties `public`, add explicit `public init(clockIn: Date, clockOut: Date?, flexWorkedNet: TimeInterval?)` (memberwise init is internal by default).
- `Urgency`: change to `public enum Urgency: String, Equatable { case normal, warning, critical }`.
- `MenuDisplay`: `public struct`, `public var state/urgency`, `public init(state:urgency:)`.
- `DisplayState`: `public enum`, `public static func computeDisplay(...)`, `public static func compute(...)`, `public var menuBarText`, `public var iconName`.
- `ParseResult`: `public struct`, `public var records/dayOffDates/timeOff` (keep internal init).
- `FlexClient`: `public final class`, `public enum FlexError`, `public init()`, `public func fetchWeek(...) -> ParseResult`.
- `FlexAPIConfig`: `public enum`, `public static let loginURL/sessionCookieNames`, `public static var userIdHash`.
- `StoredCookie`: `public struct`, `public var` fields, both inits `public`.
- `CookieVault`: `public enum`, `public static` on `defaultService`, `service`, `save`, `saveStored`, `load`, `clear`.
- `SettingsStore`: `public enum`, `public static var defaults`, `public static var rules`, `public static func manualStart/setManualStart`.
- `HookRunner`: `public final class`, `public init(defaults:execute:)`, `public func evaluate`, `public static var hooksDirectory`, `public static func launchDetached`.
- `Formatting`: `public enum`, `hm`/`signedHM`/`hms` `public static`.

In `Sources/FlexTimer/` (5 remaining files): add `import KaltoeCore` below the existing imports.

In `Tests/KaltoeCoreTests/`: change `@testable import FlexTimer` → `@testable import KaltoeCore` in every moved file.

In `Tests/FlexTimerTests/` (3 remaining files): add `import KaltoeCore` below `@testable import FlexTimer` (they reference `WorkRecord`, `CookieVault`, etc. which now live in the core module).

- [ ] **Step 4: Build and iterate on access-level errors**

Run: `swift build`
Expected: compiler errors point at any member I missed marking `public` — fix each and re-run until it succeeds. Then verify the remaining mac tests don't reference fixtures:

Run: `rg -n 'Bundle.module' Tests/FlexTimerTests/`
Expected: no matches (if any appear, keep a `resources:` clause on the FlexTimerTests target and copy the needed fixture back).

- [ ] **Step 5: Run all tests**

Run: `swift test`
Expected: all suites pass — both `KaltoeCoreTests` and `FlexTimerTests`. Same test count as before the split (no tests deleted).

- [ ] **Step 6: Verify the mac bundle still builds**

Run: `./scripts/bundle.sh`
Expected: `Built build/칼퇴타이머.app …` (release binary path `.build/release/FlexTimer` is unchanged because the executable product is still named `FlexTimer`).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: split portable logic into KaltoeCore library target"
```

---

### Task 2: Platform-split session storage (Linux file backend)

`CookieVault` keeps the Keychain on macOS and gains a `session.json` file backend on Linux. `FlexAPIConfig.userIdHash` reads from the session file on Linux. Add `FoundationNetworking` conditionals so the core compiles on Linux at all.

**Files:**

- Modify: `Sources/KaltoeCore/CookieVault.swift`
- Modify: `Sources/KaltoeCore/FlexAPIConfig.swift`
- Modify: `Sources/KaltoeCore/FlexClient.swift`
- Create: `Tests/KaltoeCoreTests/TestSupport.swift`
- Modify: `Tests/KaltoeCoreTests/CookieVaultTests.swift`, `Tests/KaltoeCoreTests/FlexClientTests.swift`

**Interfaces:**

- Produces (Linux only): `CookieVault.loadUserIdHash() -> String`, `CookieVault.sessionFileOverride: URL?` (test seam). Existing `save/saveStored/load/clear` signatures identical on both platforms.
- Produces (both platforms, tests): `useScratchVault()` free function in KaltoeCoreTests.
- Consumes: `StoredCookie` from Task 1.

**Steps:**

- [ ] **Step 1: Add FoundationNetworking conditionals**

At the top of `FlexClient.swift`, `FlexAPIConfig.swift`, and `CookieVault.swift` (after `import Foundation`):

```swift
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

(On Linux, `URLSession`/`URLRequest`/`HTTPCookie` live in FoundationNetworking; on macOS the block is a no-op.)

- [ ] **Step 2: Restructure CookieVault with a platform split**

Keep `StoredCookie` and `save(_ cookies: [HTTPCookie])` shared at the top of the file. Wrap the existing Keychain `CookieVault` body in `#if os(macOS)` and add the Linux backend in `#else`:

```swift
#if os(macOS)
// ... existing enum CookieVault body, unchanged (service, baseQuery, saveStored, load, clear) ...
#else
/// Linux: the session lives as JSON at ~/.config/kaltoe-timer/session.json
/// (0600), written by the tray frontend at login and read/updated here.
/// `expires` dates are Unix epoch seconds (the tray writes GLib to_unix()).
public enum CookieVault {
    struct SessionFile: Codable {
        var userIdHash: String
        var cookies: [StoredCookie]
    }

    /// Test seam — points reads/writes at a scratch file.
    public static var sessionFileOverride: URL?

    static var sessionFileURL: URL {
        if let sessionFileOverride { return sessionFileOverride }
        let base = ProcessInfo.processInfo.environment["KALTOE_CONFIG_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/kaltoe-timer", isDirectory: true)
        return base.appendingPathComponent("session.json")
    }

    private static func readFile() -> SessionFile? {
        guard let data = try? Data(contentsOf: sessionFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SessionFile.self, from: data)
    }

    public static func load() -> [StoredCookie]? {
        guard let file = readFile(), !file.cookies.isEmpty else { return nil }
        return file.cookies
    }

    /// The per-user Flex id captured at login; empty before first sign-in.
    public static func loadUserIdHash() -> String {
        readFile()?.userIdHash ?? ""
    }

    public static func saveStored(_ cookies: [StoredCookie]) {
        // Preserve the hash the tray wrote — cookie refreshes must not drop it.
        let file = SessionFile(userIdHash: readFile()?.userIdHash ?? "", cookies: cookies)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: sessionFileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sessionFileURL.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: sessionFileURL)
    }
}
#endif
```

Move `public static func save(_ cookies: [HTTPCookie]) { saveStored(cookies.map(StoredCookie.init)) }` outside both branches (an `extension CookieVault` below the `#endif` works).

- [ ] **Step 3: Platform-split FlexAPIConfig.userIdHash**

```swift
/// Opaque per-user identifier appearing in both endpoint URLs.
/// macOS: auto-discovered at login, stored in UserDefaults.
/// Linux: read from session.json (written by the tray frontend at login).
public static var userIdHash: String {
    #if os(macOS)
    SettingsStore.defaults.string(forKey: "flexUserIdHash") ?? ""
    #else
    CookieVault.loadUserIdHash()
    #endif
}
```

- [ ] **Step 4: Add the shared test seam**

Create `Tests/KaltoeCoreTests/TestSupport.swift`:

```swift
import Foundation
@testable import KaltoeCore

/// Points CookieVault at a scratch store so tests never touch the real session.
func useScratchVault() {
    #if os(macOS)
    CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
    #else
    CookieVault.sessionFileOverride = FileManager.default.temporaryDirectory
        .appendingPathComponent("kaltoe-vault-test-\(UUID().uuidString)/session.json")
    #endif
}
```

In `CookieVaultTests.swift` and `FlexClientTests.swift`, replace every `CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"` line with `useScratchVault()`. Wrap the keychain-specific test `testDefaultServiceIsSacrificialUnderXCTest` in `#if os(macOS)` / `#endif`.

- [ ] **Step 5: Add Linux-only vault tests (run in Task 5's Docker pass)**

Append to `CookieVaultTests.swift`:

```swift
#if !os(macOS)
extension CookieVaultTests {
    func testTrayWrittenSessionFileRoundTrips() throws {
        let url = CookieVault.sessionFileOverride!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Exactly what kaltoe-tray.py writes: epoch-seconds expires, null allowed.
        let tray = #"{"userIdHash":"u123","cookies":[{"name":"AID","value":"a","domain":".flex.team","path":"/","expires":2000000000},{"name":"V2_WS_AID","value":"w","domain":".flex.team","path":"/","expires":null}]}"#
        try tray.data(using: .utf8)!.write(to: url)
        XCTAssertEqual(CookieVault.loadUserIdHash(), "u123")
        let cookies = CookieVault.load()
        XCTAssertEqual(cookies?.map(\.name), ["AID", "V2_WS_AID"])
        XCTAssertEqual(cookies?[0].expires, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertNil(cookies?[1].expires)
    }

    func testSaveStoredPreservesUserIdHash() throws {
        let url = CookieVault.sessionFileOverride!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"userIdHash":"u123","cookies":[]}"#.data(using: .utf8)!.write(to: url)
        CookieVault.saveStored([StoredCookie(name: "AID", value: "x", domain: ".flex.team",
                                             path: "/", expires: nil)])
        XCTAssertEqual(CookieVault.loadUserIdHash(), "u123",
                       "cookie refresh must not drop the tray-written hash")
    }

    func testSessionFileWrittenOwnerOnly() throws {
        CookieVault.saveStored([StoredCookie(name: "AID", value: "x", domain: ".flex.team",
                                             path: "/", expires: nil)])
        let attrs = try FileManager.default.attributesOfItem(
            atPath: CookieVault.sessionFileOverride!.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
#endif
```

- [ ] **Step 6: Run tests on macOS**

Run: `swift test`
Expected: PASS (Linux-only tests are compiled out here; they get exercised in Task 5).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: Linux file-backed session store behind platform split"
```

---

### Task 3: Extract WeekData and add StatusLine (core, TDD)

Move `todayRecord`/`weekIncludingManual` from `AppState` into a core `WeekData` struct (so the daemon reuses them instead of duplicating), and add the `StatusLine` NDJSON contract type.

**Files:**

- Create: `Sources/KaltoeCore/WeekData.swift`
- Create: `Sources/KaltoeCore/StatusLine.swift`
- Modify: `Sources/FlexTimer/AppState.swift`
- Create: `Tests/KaltoeCoreTests/WeekDataTests.swift`, `Tests/KaltoeCoreTests/StatusLineTests.swift`

**Interfaces:**

- Produces: `public struct WeekData { init(records:dayOffDates:timeOff:); func todayRecord(now:) -> WorkRecord?; func weekIncludingManual(now:) -> [WorkRecord]; vars records/dayOffDates/timeOff }`
- Produces: `public struct StatusLine: Codable, Equatable { text, icon, urgency, hasSession, lastSync, syncError; init(display:hasSession:lastSync:syncError:); static func encoder() -> JSONEncoder }`
- Consumes: `MenuDisplay`, `Urgency.rawValue`, `DisplayState.menuBarText/iconName`, `SettingsStore.manualStart` from Tasks 1–2.

**Steps:**

- [ ] **Step 1: Write the failing tests**

`Tests/KaltoeCoreTests/StatusLineTests.swift`:

```swift
import XCTest
@testable import KaltoeCore

final class StatusLineTests: XCTestCase {
    func testMapsDisplayFields() {
        let line = StatusLine(display: MenuDisplay(state: .overtime(weekly: -59 * 60),
                                                   urgency: .critical),
                              hasSession: true, lastSync: nil, syncError: nil)
        XCTAssertEqual(line.text, "OT -0:59")
        XCTAssertEqual(line.icon, "timer")
        XCTAssertEqual(line.urgency, "critical")
    }

    func testEncodesStableSortedJSONOmittingNils() throws {
        let line = StatusLine(display: MenuDisplay(state: .noSession, urgency: .normal),
                              hasSession: false, lastSync: nil, syncError: nil)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8)
        XCTAssertEqual(json, #"{"hasSession":false,"icon":"timer","text":"—","urgency":"normal"}"#)
    }

    func testEncodesLastSyncAsISO8601() throws {
        let line = StatusLine(display: MenuDisplay(state: .notClockedIn, urgency: .normal),
                              hasSession: true,
                              lastSync: Date(timeIntervalSince1970: 0), syncError: nil)
        let json = String(data: try StatusLine.encoder().encode(line), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""lastSync":"1970-01-01T00:00:00Z""#), json)
    }
}
```

`Tests/KaltoeCoreTests/WeekDataTests.swift`:

```swift
import XCTest
@testable import KaltoeCore

final class WeekDataTests: XCTestCase {
    override func setUp() {
        SettingsStore.defaults = UserDefaults(suiteName: "kaltoe-weekdata-\(UUID().uuidString)")!
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d,
                                                   hour: h, minute: mi))!
    }

    func testTodayRecordPrefersFlexOverManual() {
        let now = date(2026, 7, 8, 14, 0)
        let flex = WorkRecord(clockIn: date(2026, 7, 8, 9, 0), clockOut: nil, flexWorkedNet: nil)
        SettingsStore.setManualStart(date(2026, 7, 8, 10, 0), on: now)
        let data = WeekData(records: [flex], dayOffDates: [], timeOff: [:])
        XCTAssertEqual(data.todayRecord(now: now), flex)
    }

    func testTodayRecordFallsBackToManual() {
        let now = date(2026, 7, 8, 14, 0)
        let manual = date(2026, 7, 8, 10, 0)
        SettingsStore.setManualStart(manual, on: now)
        let data = WeekData(records: [], dayOffDates: [], timeOff: [:])
        XCTAssertEqual(data.todayRecord(now: now),
                       WorkRecord(clockIn: manual, clockOut: nil, flexWorkedNet: nil))
    }

    func testWeekIncludingManualAppendsSyntheticToday() {
        let now = date(2026, 7, 8, 14, 0)
        let monday = WorkRecord(clockIn: date(2026, 7, 6, 9, 0),
                                clockOut: date(2026, 7, 6, 18, 0), flexWorkedNet: 8 * 3600)
        SettingsStore.setManualStart(date(2026, 7, 8, 10, 0), on: now)
        let data = WeekData(records: [monday], dayOffDates: [], timeOff: [:])
        XCTAssertEqual(data.weekIncludingManual(now: now).count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StatusLineTests --filter WeekDataTests`
Expected: FAIL to compile — `WeekData`/`StatusLine` not defined.

- [ ] **Step 3: Implement WeekData**

`Sources/KaltoeCore/WeekData.swift` — logic lifted verbatim from `AppState.todayRecord`/`weekIncludingManual`:

```swift
import Foundation

/// Snapshot of a fetched week plus the manual-start fallback, shared by the
/// macOS AppState and the Linux headless daemon.
public struct WeekData {
    public var records: [WorkRecord]
    public var dayOffDates: Set<Date>
    public var timeOff: [Date: TimeInterval]

    public init(records: [WorkRecord] = [], dayOffDates: Set<Date> = [],
                timeOff: [Date: TimeInterval] = [:]) {
        self.records = records
        self.dayOffDates = dayOffDates
        self.timeOff = timeOff
    }

    /// Flex record for the day if present, else a synthetic record from manual entry.
    public func todayRecord(now: Date) -> WorkRecord? {
        if let flex = records.first(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }) {
            return flex
        }
        if let manual = SettingsStore.manualStart(on: now) {
            return WorkRecord(clockIn: manual, clockOut: nil, flexWorkedNet: nil)
        }
        return nil
    }

    /// Week records including the synthetic manual record for today, if any.
    public func weekIncludingManual(now: Date) -> [WorkRecord] {
        let weekStart = WorkCalculator.weekStart(of: now)
        var result = records.filter { $0.clockIn >= weekStart }
        if !result.contains(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }),
           let manual = todayRecord(now: now) {
            result.append(manual)
        }
        return result
    }
}
```

- [ ] **Step 4: Implement StatusLine**

`Sources/KaltoeCore/StatusLine.swift`:

```swift
import Foundation

/// One NDJSON status line emitted by the kaltoe-core daemon and consumed by
/// the Linux tray (linux/kaltoe-tray.py). Field set is part of that contract;
/// nil optionals are omitted from the JSON.
public struct StatusLine: Codable, Equatable {
    public var text: String
    public var icon: String
    public var urgency: String
    public var hasSession: Bool
    public var lastSync: Date?
    public var syncError: String?

    public init(display: MenuDisplay, hasSession: Bool, lastSync: Date?, syncError: String?) {
        self.text = display.state.menuBarText
        self.icon = display.state.iconName
        self.urgency = display.urgency.rawValue
        self.hasSession = hasSession
        self.lastSync = lastSync
        self.syncError = syncError
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
```

- [ ] **Step 5: Run the new tests**

Run: `swift test --filter StatusLineTests --filter WeekDataTests`
Expected: PASS.

- [ ] **Step 6: Make AppState delegate to WeekData**

In `Sources/FlexTimer/AppState.swift`, replace the bodies of `todayRecord(now:)` and `weekIncludingManual(now:)`:

```swift
var weekData: WeekData { WeekData(records: week, dayOffDates: dayOffDates, timeOff: timeOff) }

/// Flex record for the day if present, else a synthetic record from manual entry.
func todayRecord(now: Date) -> WorkRecord? {
    weekData.todayRecord(now: now)
}

/// Week records including the synthetic manual record for today, if any.
func weekIncludingManual(now: Date) -> [WorkRecord] {
    weekData.weekIncludingManual(now: now)
}
```

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS — `AppStateTests` prove the delegation preserved behavior.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: extract WeekData into core and add StatusLine NDJSON contract"
```

---

### Task 4: Implement the kaltoe-core daemon

Replace the placeholder with the real headless loop: refresh every 600 s (or on stdin input), recompute every 1 s, emit `StatusLine` on change + 60 s heartbeat, exit on stdin EOF.

**Files:**

- Create: `Sources/KaltoeDaemon/HeadlessState.swift`
- Modify: `Sources/KaltoeDaemon/main.swift` (replace placeholder)

**Interfaces:**

- Consumes: `FlexClient.fetchWeek`, `WeekData`, `DisplayState.computeDisplay`, `StatusLine`, `CookieVault.load`, `SettingsStore.rules`, `WorkCalculator.weekStart` from Tasks 1–3.
- Produces: `kaltoe-core` binary protocol — NDJSON on stdout; stdin line = force refresh; stdin EOF = exit. `linux/kaltoe-tray.py` (Task 7) relies on exactly this.

**Steps:**

- [ ] **Step 1: Write HeadlessState**

`Sources/KaltoeDaemon/HeadlessState.swift` — mirrors `AppState.refresh` minus UI:

```swift
import Foundation
import KaltoeCore

/// AppState's fetch/compute loop without the AppKit shell. Same refresh
/// semantics: sync failure keeps last data, dead session flips hasSession.
@MainActor
final class HeadlessState {
    private let client = FlexClient()
    private(set) var weekData = WeekData()
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    private(set) var hasSession = CookieVault.load()?.isEmpty == false

    func refresh() async {
        do {
            let now = Date()
            let weekStart = WorkCalculator.weekStart(of: now)
            let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? now
            let result = try await client.fetchWeek(from: weekStart, to: max(now, weekEnd))
            weekData = WeekData(records: result.records, dayOffDates: result.dayOffDates,
                                timeOff: result.timeOff)
            lastSync = now
            syncError = nil
            hasSession = true
        } catch let e as FlexClient.FlexError where e == .noSession || e == .sessionExpired {
            hasSession = false
        } catch {
            syncError = "Flex sync failed — showing last known data"
        }
    }

    func status(now: Date) -> StatusLine {
        let display = DisplayState.computeDisplay(hasSession: hasSession,
                                                  today: weekData.todayRecord(now: now),
                                                  week: weekData.weekIncludingManual(now: now),
                                                  dayOffs: weekData.dayOffDates,
                                                  timeOff: weekData.timeOff,
                                                  now: now, rules: SettingsStore.rules)
        return StatusLine(display: display, hasSession: hasSession,
                          lastSync: lastSync, syncError: syncError)
    }
}
```

- [ ] **Step 2: Write main.swift**

```swift
import Dispatch
import Foundation
import KaltoeCore

/// Headless 칼퇴타이머 core for the Linux tray. Protocol (see
/// linux/kaltoe-tray.py): NDJSON StatusLine on stdout, emitted on change and
/// at least every 60 s; any stdin line forces a refresh; stdin EOF exits.

final class RefreshFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = raised; raised = false; return value
    }
}

let refreshFlag = RefreshFlag()

Thread.detachNewThread {
    while readLine(strippingNewline: true) != nil { refreshFlag.raise() }
    exit(0) // stdin closed — the tray frontend is gone
}

Task { @MainActor in
    let state = HeadlessState()
    let encoder = StatusLine.encoder()
    var lastEmitted: StatusLine?
    var lastEmitAt = Date.distantPast
    var tick = 0
    while true {
        if tick % 600 == 0 || refreshFlag.consume() { await state.refresh() }
        let now = Date()
        let line = state.status(now: now)
        if line != lastEmitted || now.timeIntervalSince(lastEmitAt) >= 60 {
            if let data = try? encoder.encode(line),
               let json = String(data: data, encoding: .utf8) {
                print(json)
                fflush(stdout)
                lastEmitted = line
                lastEmitAt = now
            }
        }
        tick += 1
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

dispatchMain()
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds; `.build/debug/kaltoe-core` exists.

Do NOT run the binary on macOS — outside XCTest it points at the real Keychain service and would trigger a securityd consent prompt (and read your real Flex session). The runtime smoke test happens inside Docker in Task 5.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS (no new tests; daemon glue is exercised by the Task 5 smoke run).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: kaltoe-core headless daemon emitting NDJSON status"
```

---

### Task 5: Validate on Linux in Docker

First contact with Linux: run the core tests and a daemon smoke test inside `swift:6.1-noble`. Fix whatever Foundation-on-Linux differences surface.

**Files:**

- Modify: `.gitignore` (add `.build-linux/`)
- Possibly modify: `Sources/KaltoeCore/*.swift` (Linux fixes)

**Interfaces:**

- Consumes: everything from Tasks 1–4.
- Produces: proof that `KaltoeCoreTests` pass and `kaltoe-core` runs on Linux.

**Steps:**

- [ ] **Step 1: Add the Linux scratch dir to .gitignore**

Append `.build-linux/` to `.gitignore`.

- [ ] **Step 2: Run the test suite in Docker**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  swift:6.1-noble swift test --scratch-path .build-linux
```

Expected: all `KaltoeCoreTests` pass, including the `#if !os(macOS)` vault tests from Task 2 (the macOS targets don't exist in the Linux manifest evaluation, so nothing AppKit is built). First run downloads the image and is slow under emulation on Apple Silicon — that's normal.

Known-likely failures and their fixes (apply only what actually fails):

- **`weekStart` off by a day**: the container's POSIX locale makes `Calendar.current.firstWeekday` Sunday. Fix in `WorkCalculator.weekStart` by forcing Monday: `var cal = calendar; cal.firstWeekday = 2` before computing the week interval.
- **Missing `FoundationNetworking` symbol errors in test files**: add the same `#if canImport(FoundationNetworking)` import block to the affected test file.
- **`UserDefaults(suiteName:)` persistence quirks**: if a SettingsStore test fails on read-back, register the value into `defaults` via `set` + immediate read in the same instance (corelibs-foundation honors this).

- [ ] **Step 3: Build the release binary for Linux**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  swift:6.1-noble swift build -c release --product kaltoe-core --static-swift-stdlib \
  --scratch-path .build-linux
```

Expected: succeeds; `.build-linux/release/kaltoe-core` exists and `file` reports an x86-64 ELF executable.

- [ ] **Step 4: Daemon smoke test (no session)**

Run:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  -e KALTOE_CONFIG_DIR=/tmp/kaltoe-none \
  swift:6.1-noble bash -c 'sleep 3 | .build-linux/release/kaltoe-core | head -n 1'
```

Expected output (exactly): `{"hasSession":false,"icon":"timer","text":"—","urgency":"normal"}`
Also verify EOF exit: `printf '' | .build-linux/release/kaltoe-core` (same docker wrapper) must exit promptly with status 0, not hang.

- [ ] **Step 5: Run mac tests to confirm nothing regressed**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix: KaltoeCore passes tests and daemon smoke on Linux"
```

(If Step 2 needed zero fixes, the commit is just the .gitignore line — commit it with `chore: ignore .build-linux scratch dir`.)

---

### Task 6: Tray icon SVGs

3 glyphs (timer, fork, cup) × 3 urgency colors, generated by a script so they can be regenerated/tweaked. Colors: default `#dfdfdf` (light gray for dark panels), warning `#ff9500` (orange), critical `#ff3b30` (red) — matching the Mac pill colors.

**Files:**

- Create: `scripts/gen-linux-icons.sh`
- Create (generated): `linux/icons/kaltoe-{timer,fork,cup}.svg`, `linux/icons/kaltoe-{timer,fork,cup}-{warning,critical}.svg` (9 files)

**Interfaces:**

- Produces: icon names `kaltoe-timer`, `kaltoe-fork`, `kaltoe-cup` (+ `-warning`/`-critical` suffixes) that Task 7's `ICON_BASE` map and `set_icon_theme_path` rely on.

**Steps:**

- [ ] **Step 1: Write the generator**

`scripts/gen-linux-icons.sh`:

```bash
#!/bin/bash
# Generates the Linux tray icon SVGs (3 glyphs × 3 urgency colors) into linux/icons/.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=linux/icons
mkdir -p "$OUT"

emit() { # $1=file-basename $2=stroke-color $3=glyph-body
  cat > "$OUT/$1.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">
<g fill="none" stroke="$2" stroke-width="1.8" stroke-linecap="round">
$3
</g>
</svg>
EOF
}

TIMER='<circle cx="11" cy="12.5" r="6.5"/><path d="M11 12.5V9"/><path d="M9 2.5h4"/><path d="M11 2.5v3"/>'
FORK='<path d="M7 3v5"/><path d="M10 3v5"/><path d="M13 3v5"/><path d="M7 8a3 3 0 0 0 6 0"/><path d="M10 11v8"/>'
CUP='<path d="M5 7h10v5a5 5 0 0 1-10 0z"/><path d="M15 8h1.5a2.5 2.5 0 0 1 0 5H15"/><path d="M5 19h12"/>'

for pair in "timer|$TIMER" "fork|$FORK" "cup|$CUP"; do
  glyph="${pair%%|*}" body="${pair#*|}"
  emit "kaltoe-$glyph"          "#dfdfdf" "$body"
  emit "kaltoe-$glyph-warning"  "#ff9500" "$body"
  emit "kaltoe-$glyph-critical" "#ff3b30" "$body"
done
echo "Wrote 9 SVGs to $OUT"
```

- [ ] **Step 2: Generate and eyeball**

Run: `chmod +x scripts/gen-linux-icons.sh && ./scripts/gen-linux-icons.sh && ls linux/icons`
Expected: 9 `.svg` files. Open `linux/icons/kaltoe-timer.svg` (e.g. `qlmanage -p` or a browser) and confirm each glyph reads as a stopwatch / fork / cup at small size.

- [ ] **Step 3: Commit**

```bash
git add scripts/gen-linux-icons.sh linux/icons
git commit -m "feat: Linux tray icon set (3 glyphs x 3 urgency colors)"
```

---

### Task 7: The tray frontend — linux/kaltoe-tray.py

Complete GTK frontend: spawns/supervises `kaltoe-core`, renders status, hosts the WebKitGTK login, writes `session.json`, notifies on session expiry.

**Files:**

- Create: `linux/kaltoe-tray.py`

**Interfaces:**

- Consumes: `kaltoe-core` NDJSON protocol (Task 4), icon names (Task 6), `session.json` format (Task 2 / Global Constraints).
- Produces: the executable the coworker runs; `install.sh` (Task 8) points the autostart entry at it.

**Steps:**

- [ ] **Step 1: Write the frontend**

`linux/kaltoe-tray.py` (complete file):

```python
#!/usr/bin/env python3
"""칼퇴타이머 Linux tray frontend.

Spawns the kaltoe-core daemon, mirrors its NDJSON status lines in an
AppIndicator tray item, and hosts the flex.team login window (WebKitGTK).
Design: docs/superpowers/specs/2026-07-10-linux-build-design.md.
"""
import json
import os
import subprocess
import urllib.parse
from pathlib import Path

import gi

try:
    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.1")
    gi.require_version("Soup", "3.0")
except ValueError as e:
    raise SystemExit(
        f"Missing GTK/WebKit introspection data ({e}).\n"
        "Install the dependencies:\n"
        "  sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1 "
        "gir1.2-webkit2-4.1 libnotify-bin")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except ValueError:  # older distros ship the pre-Ayatana name
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as AppIndicator
    except ValueError:
        raise SystemExit(
            "No AppIndicator introspection data found.\n"
            "Install it:  sudo apt install gir1.2-ayatanaappindicator3-0.1")
from gi.repository import GLib, Gtk, WebKit2

APP_DIR = Path(__file__).resolve().parent
CORE_BIN = str(APP_DIR / "kaltoe-core")
ICON_DIR = str(APP_DIR / "icons")
CONFIG_DIR = Path(os.environ.get("KALTOE_CONFIG_DIR") or Path.home() / ".config" / "kaltoe-timer")
SESSION_FILE = CONFIG_DIR / "session.json"
LOGIN_URL = "https://flex.team/sign-in"
SESSION_COOKIE_NAMES = {"AID", "V2_WS_AID"}  # mirrors FlexAPIConfig.sessionCookieNames
ICON_BASE = {"timer": "kaltoe-timer", "fork.knife": "kaltoe-fork", "cup.and.saucer": "kaltoe-cup"}
LABEL_GUIDE = "OT +88:88"  # widest label, reserves tray width


class TrayApp:
    def __init__(self):
        self.proc = None
        self.core_gen = 0
        self.buf = b""
        self.has_session = None
        self.login_window = None
        self.indicator = AppIndicator.Indicator.new(
            "kaltoe-timer", "kaltoe-timer", AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_icon_theme_path(ICON_DIR)
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_label("--:--", LABEL_GUIDE)
        self._build_menu()
        self.start_core()

    # ---- menu ----

    def _build_menu(self):
        menu = Gtk.Menu()
        self.status_item = Gtk.MenuItem(label="Starting…")
        self.status_item.set_sensitive(False)
        menu.append(self.status_item)
        menu.append(Gtk.SeparatorMenuItem())

        self.sign_in_item = Gtk.MenuItem(label="Sign in to Flex…")
        self.sign_in_item.connect("activate", self.open_login)
        menu.append(self.sign_in_item)

        self.sign_out_item = Gtk.MenuItem(label="Sign out")
        self.sign_out_item.connect("activate", self.sign_out)
        menu.append(self.sign_out_item)

        refresh_item = Gtk.MenuItem(label="Refresh now")
        refresh_item.connect("activate", self.request_refresh)
        menu.append(refresh_item)

        self.restart_item = Gtk.MenuItem(label="Restart core")
        self.restart_item.connect("activate", self.start_core)
        menu.append(self.restart_item)

        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self.quit)
        menu.append(quit_item)

        menu.show_all()
        self.restart_item.hide()
        self.indicator.set_menu(menu)

    # ---- core subprocess ----

    def start_core(self, *_):
        self.stop_core()
        self.core_gen += 1
        gen = self.core_gen
        try:
            self.proc = subprocess.Popen([CORE_BIN], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE)
        except OSError as e:
            self.on_core_dead(f"core failed to start: {e}")
            return
        self.restart_item.hide()
        self.buf = b""
        GLib.io_add_watch(self.proc.stdout.fileno(), GLib.IO_IN | GLib.IO_HUP,
                          lambda fd, cond: self.on_core_output(fd, cond, gen))

    def stop_core(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def on_core_dead(self, message):
        self.indicator.set_label("--:--", LABEL_GUIDE)
        self.indicator.set_icon_full("kaltoe-timer", "core stopped")
        self.status_item.set_label(message)
        self.restart_item.show()

    def on_core_output(self, fd, cond, gen):
        if gen != self.core_gen:
            return False  # watch for a previous core generation — drop it
        chunk = b""
        if cond & GLib.IO_IN:
            chunk = os.read(fd, 65536)
            self.buf += chunk
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                self.apply_status(line)
        if (cond & GLib.IO_HUP) and not chunk:
            self.on_core_dead("core stopped — use Restart core")
            return False
        return True

    def request_refresh(self, *_):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.stdin.write(b"refresh\n")
                self.proc.stdin.flush()
            except OSError:
                pass

    # ---- status rendering ----

    def apply_status(self, raw):
        try:
            status = json.loads(raw)
        except ValueError:
            return
        text = status.get("text", "--:--")
        icon = ICON_BASE.get(status.get("icon"), "kaltoe-timer")
        urgency = status.get("urgency", "normal")
        if urgency in ("warning", "critical"):
            icon = f"{icon}-{urgency}"
        self.indicator.set_label(text, LABEL_GUIDE)
        self.indicator.set_icon_full(icon, text)

        has_session = status.get("hasSession", False)
        parts = []
        if not has_session:
            parts.append("Signed out")
        if status.get("syncError"):
            parts.append(status["syncError"])
        if status.get("lastSync"):
            parts.append("Synced " + status["lastSync"].replace("T", " ")[:16])
        self.status_item.set_label(" · ".join(parts) or "OK")
        self.sign_in_item.set_visible(not has_session)
        self.sign_out_item.set_visible(has_session)

        if self.has_session and not has_session:
            subprocess.run(["notify-send", "칼퇴타이머",
                            "Flex session expired — sign in again to keep tracking."],
                           check=False)
        self.has_session = has_session

    # ---- login (mirrors macOS LoginWindowController) ----

    def open_login(self, *_):
        if self.login_window:
            self.login_window.present()
            return
        win = Gtk.Window(title="Sign in to Flex")
        win.set_default_size(480, 680)
        web = WebKit2.WebView()
        web.connect("load-changed", self.on_load_changed)
        win.add(web)
        win.connect("destroy", self.on_login_closed)
        win.show_all()
        web.load_uri(LOGIN_URL)
        self.login_window = win

    def on_login_closed(self, *_):
        self.login_window = None

    def on_load_changed(self, web, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        manager = web.get_website_data_manager().get_cookie_manager()
        manager.get_cookies("https://flex.team", None, self.on_cookies_ready)

    def on_cookies_ready(self, manager, result):
        try:
            cookies = manager.get_cookies_finish(result)
        except GLib.Error:
            return
        flex = [c for c in cookies if "flex.team" in c.get_domain()]
        names = {c.get_name() for c in flex}
        if not SESSION_COOKIE_NAMES <= names:
            return  # not logged in yet — keep waiting for later page loads
        user_id_hash = ""
        for c in flex:
            if c.get_name() == "V2_CUSTOMER_INFO":
                try:
                    info = json.loads(urllib.parse.unquote(c.get_value()))
                    user_id_hash = info.get("userIdHash") or ""
                except ValueError:
                    pass
        if not user_id_hash:
            return  # the id cookie hasn't landed yet
        self.write_session(user_id_hash, flex)
        if self.login_window:
            self.login_window.destroy()
        self.start_core()  # restart so the core picks up the new session

    @staticmethod
    def expires_epoch(cookie):
        expires = cookie.get_expires()  # GLib.DateTime or None (session cookie)
        return expires.to_unix() if expires else None

    def write_session(self, user_id_hash, cookies):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "userIdHash": user_id_hash,
            "cookies": [
                {"name": c.get_name(), "value": c.get_value(), "domain": c.get_domain(),
                 "path": c.get_path(), "expires": self.expires_epoch(c)}
                for c in cookies
            ],
        }
        fd = os.open(SESSION_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)

    # ---- lifecycle ----

    def sign_out(self, *_):
        SESSION_FILE.unlink(missing_ok=True)
        self.start_core()

    def quit(self, *_):
        self.stop_core()
        Gtk.main_quit()


def main():
    if not os.path.exists(CORE_BIN):
        raise SystemExit(f"kaltoe-core binary not found next to this script: {CORE_BIN}\n"
                         "Run from the installed directory (see README-linux.md).")
    TrayApp()
    Gtk.main()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Syntax-check (GTK can't run on macOS)**

Run: `python3 -m py_compile linux/kaltoe-tray.py && chmod +x linux/kaltoe-tray.py && echo OK`
Expected: `OK`. (Behavioral testing happens in the manual Ubuntu smoke test — Task 8 Step 6.)

- [ ] **Step 3: Commit**

```bash
git add linux/kaltoe-tray.py
git commit -m "feat: Linux tray frontend with WebKitGTK Flex login"
```

---

### Task 8: Packaging — build-linux.sh, install.sh, README-linux.md

Produce the distributable tarball and the coworker-facing docs; note the Linux build in the main README.

**Files:**

- Create: `scripts/build-linux.sh`
- Create: `linux/install.sh`
- Create: `linux/README-linux.md`
- Modify: `README.md` (add a short "Linux build" section)

**Interfaces:**

- Consumes: `kaltoe-core` product (Task 1/4/5), `linux/kaltoe-tray.py` (Task 7), `linux/icons/` (Task 6).
- Produces: `build/kaltoe-timer-linux-x86_64.tar.gz`.

**Steps:**

- [ ] **Step 1: Write scripts/build-linux.sh**

```bash
#!/bin/bash
# Builds kaltoe-core for x86_64 Linux in Docker and assembles the
# distributable tarball. Requires Docker (OrbStack/colima work).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=swift:6.1-noble
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src -e HOME=/tmp \
  "$IMAGE" swift build -c release --product kaltoe-core --static-swift-stdlib \
  --scratch-path .build-linux

OUT=build/kaltoe-timer-linux
rm -rf "$OUT"
mkdir -p "$OUT/icons"
cp .build-linux/release/kaltoe-core "$OUT/"
cp linux/kaltoe-tray.py linux/install.sh linux/README-linux.md "$OUT/"
cp linux/icons/*.svg "$OUT/icons/"
chmod +x "$OUT/kaltoe-core" "$OUT/kaltoe-tray.py" "$OUT/install.sh"

tar -C build -czf build/kaltoe-timer-linux-x86_64.tar.gz kaltoe-timer-linux
echo "Built build/kaltoe-timer-linux-x86_64.tar.gz"
```

- [ ] **Step 2: Write linux/install.sh**

```bash
#!/bin/bash
# Installs 칼퇴타이머 for the current user and registers autostart.
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/.local/share/kaltoe-timer"
mkdir -p "$DEST/icons" "$HOME/.config/autostart"
cp kaltoe-core kaltoe-tray.py README-linux.md "$DEST/"
cp icons/*.svg "$DEST/icons/"
chmod +x "$DEST/kaltoe-core" "$DEST/kaltoe-tray.py"

cat > "$HOME/.config/autostart/kaltoe-timer.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=칼퇴타이머
Comment=Work-hours tray timer for flex.team
Exec=$DEST/kaltoe-tray.py
X-GNOME-Autostart-enabled=true
EOF

echo "Installed to $DEST (autostarts at login)."
echo "Start it now with:  $DEST/kaltoe-tray.py &"
```

- [ ] **Step 3: Write linux/README-linux.md**

```markdown
# 칼퇴타이머 for Linux (Ubuntu)

Tray timer for flex.team work hours — the Linux port of the macOS menu bar app.

## Requirements

Ubuntu 22.04+ with GNOME (or any desktop with AppIndicator/StatusNotifier
support). Install the system dependencies:

    sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1 \
                     gir1.2-webkit2-4.1 libnotify-bin

On stock Ubuntu GNOME the AppIndicator extension
(`gnome-shell-extension-appindicator`) must be enabled — it ships enabled on
Ubuntu 22.04+.

## Install

    tar xzf kaltoe-timer-linux-x86_64.tar.gz
    cd kaltoe-timer-linux
    ./install.sh

The app autostarts at login. Start it immediately with:

    ~/.local/share/kaltoe-timer/kaltoe-tray.py &

## First run

Click the tray icon → **Sign in to Flex…** and log in with your normal Flex
credentials. The session is saved to `~/.config/kaltoe-timer/session.json`
(readable only by your user). When the session expires (a desktop
notification tells you), sign in again the same way.

## What the tray shows

Same phases as the Mac app: countdown to lunch (fork icon), break (cup),
countdown to leave time (timer), and the weekly overtime counter (`OT -2:59`)
after leave time. The icon turns orange within 30 minutes of leave time and
red within 10 minutes or while overworking.

## Uninstall

    rm -rf ~/.local/share/kaltoe-timer ~/.config/kaltoe-timer \
           ~/.config/autostart/kaltoe-timer.desktop
```

- [ ] **Step 4: Add a Linux section to the main README**

Append to `README.md` (after the existing build/distribution material):

```markdown
## Linux build

A Linux (Ubuntu) port ships as a tray app: the portable `KaltoeCore` logic is
compiled into a headless `kaltoe-core` daemon and fronted by
`linux/kaltoe-tray.py` (AppIndicator + WebKitGTK login). Build the
distributable with:

    ./scripts/build-linux.sh   # requires Docker; outputs build/kaltoe-timer-linux-x86_64.tar.gz

Install instructions for the recipient are in `linux/README-linux.md`.
```

- [ ] **Step 5: Build the tarball**

Run: `chmod +x scripts/build-linux.sh linux/install.sh && ./scripts/build-linux.sh && tar tzf build/kaltoe-timer-linux-x86_64.tar.gz`
Expected: tarball listing shows `kaltoe-timer-linux/kaltoe-core`, `kaltoe-tray.py`, `install.sh`, `README-linux.md`, and 9 files under `icons/`.

- [ ] **Step 6: Manual Ubuntu smoke test (on the coworker's machine or a VM)**

Checklist to hand over with the tarball:

1. `sudo apt install …` (deps above), extract, `./install.sh`, launch.
2. Tray shows `—` with the timer icon (signed out).
3. Sign in via the menu → Flex login page appears → after login the window closes itself and the label updates within ~10 s.
4. Phase sanity: label/icon matches the Mac app for the same account.
5. Quit → `kaltoe-core` process is gone (`pgrep -f kaltoe-core` empty).
6. Re-login test: delete `~/.config/kaltoe-timer/session.json`, use "Refresh now" — a notification appears and the menu offers Sign in.

- [ ] **Step 7: Run the full mac suite one last time and commit**

Run: `swift test && ./scripts/bundle.sh`
Expected: tests pass; mac bundle builds.

```bash
git add -A
git commit -m "feat: Linux packaging — build script, installer, docs"
```
