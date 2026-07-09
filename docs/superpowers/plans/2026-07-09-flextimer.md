# FlexTimer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app that shows a countdown to leave time (clock-in + 9h, from flex.team records) and the week's overtime position vs. a 5h/week requirement.

**Architecture:** Swift Package Manager executable using SwiftUI `MenuBarExtra`. Four units: pure `WorkCalculator` (all business math, fully unit-tested), `FlexClient` (private-API fetch + Keychain-stored session cookies captured via a `WKWebView` login window), `AppState` (observable state machine: 1s tick, 10-min refresh, wake refresh), and a dropdown view with manual-start-time fallback.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, WebKit, Security (Keychain), Foundation. Zero third-party dependencies.

## Global Constraints

- Platform: macOS 13+ (`MenuBarExtra` requires it). Build/test with `swift build` / `swift test` (SPM only, no Xcode project).
- Zero third-party dependencies.
- Rules defaults (user-overridable via UserDefaults, Task 9): daily work `8h`, fixed break `1h`, weekly overtime requirement `5h`, week starts **Monday 00:00** local time.
- Menu bar copy, exactly: counting `⏳ 2:34`, overtime `OT -2:59` / `OT +0:12`, not clocked in `⏳ --:--`, no session `⏳ —`.
- Overtime sign convention: weekly counter starts at `-5:00` each Monday and increases; negative = still owed.
- App name `FlexTimer`, bundle id `com.perso.flextimer`, Keychain service `com.perso.flextimer.session`.
- Spec: `docs/superpowers/specs/2026-07-09-flextimer-design.md`. Canonical examples: clock-in 08:59 → leave 17:59; Monday 09:01–20:02 with nothing else this week → weekly OT `-2:59`.
- All date tests pin `TimeZone(identifier: "Asia/Seoul")` so they don't depend on machine settings.

---

### Task 1: Project scaffold — SPM package with a static menu bar item

**Files:**

- Create: `Package.swift`
- Create: `Sources/FlexTimer/FlexTimerApp.swift`
- Create: `Sources/FlexTimer/AppDelegate.swift`
- Create: `Tests/FlexTimerTests/SmokeTests.swift`
- Create: `.gitignore`

**Interfaces:**

- Consumes: nothing.
- Produces: an app target later tasks add files to; `FlexTimerApp` will later swap its hardcoded label for `AppState.menuText` (Task 8).

- [ ] **Step 1: Write Package.swift, .gitignore, and app entry**

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlexTimer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FlexTimer", path: "Sources/FlexTimer"),
        .testTarget(name: "FlexTimerTests", dependencies: ["FlexTimer"], path: "Tests/FlexTimerTests",
                    resources: [.copy("Fixtures")]),
    ]
)
```

`.gitignore`:

```
.build/
build/
.DS_Store
```

`Sources/FlexTimer/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    }
}
```

`Sources/FlexTimer/FlexTimerApp.swift`:

```swift
import SwiftUI

@main
struct FlexTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Text("⏳ --:--")
        }
    }
}
```

`Tests/FlexTimerTests/SmokeTests.swift` (also create an empty `Tests/FlexTimerTests/Fixtures/.gitkeep` so the resource dir exists):

```swift
import XCTest

final class SmokeTests: XCTestCase {
    func testTruth() { XCTAssertTrue(true) }
}
```

- [ ] **Step 2: Verify it builds and tests run**

Run: `swift build && swift test`
Expected: `Build complete!` and `Executed 1 test, with 0 failures`.

- [ ] **Step 3: Verify the menu bar item appears**

Run: `swift run &` — expected: an `⏳ --:--` item appears in the macOS menu bar, no Dock icon; clicking it shows Quit. Then quit it via the menu (or `kill %1`).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: scaffold SPM menu bar app"
```

---

### Task 2: WorkCalculator — all business math (pure, TDD)

**Files:**

- Create: `Sources/FlexTimer/WorkCalculator.swift`
- Test: `Tests/FlexTimerTests/WorkCalculatorTests.swift`

**Interfaces:**

- Consumes: nothing (pure Foundation).
- Produces (used by Tasks 3, 6, 8):
    - `struct WorkRules { var dailyWork, breakTime, weeklyOvertime: TimeInterval }` (defaults 8h/1h/5h)
    - `struct WorkRecord { var clockIn: Date; var clockOut: Date?; var flexWorkedNet: TimeInterval? }`
    - `WorkCalculator.leaveTime(clockIn:rules:) -> Date`
    - `WorkCalculator.timeLeft(clockIn:now:rules:) -> TimeInterval`
    - `WorkCalculator.dailyOvertime(record:now:rules:) -> TimeInterval`
    - `WorkCalculator.weeklyOvertime(records:now:rules:) -> TimeInterval`
    - `WorkCalculator.weekStart(of:calendar:) -> Date`

- [ ] **Step 1: Write the failing tests**

`Tests/FlexTimerTests/WorkCalculatorTests.swift`:

```swift
import XCTest
@testable import FlexTimer

/// Date in Asia/Seoul, gregorian.
func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal.date(from: DateComponents(year: y, month: mo, day: da, hour: h, minute: mi))!
}

let rules = WorkRules()

final class WorkCalculatorTests: XCTestCase {
    // Spec canonical: clock in 08:59 → leave 17:59 (start + 8h work + 1h break)
    func testLeaveTime() {
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 6, 8, 59), rules: rules),
                       d(2026, 7, 6, 17, 59))
    }

    func testTimeLeftMidDay() {
        // at 14:27, 3h32m left until 17:59
        XCTAssertEqual(WorkCalculator.timeLeft(clockIn: d(2026, 7, 6, 8, 59),
                                               now: d(2026, 7, 6, 14, 27), rules: rules),
                       3 * 3600 + 32 * 60)
    }

    func testDailyOvertimeCompletedDay() {
        // Spec canonical: Mon 09:01–20:02 → 11h01 gross − 1h break − 8h target = +2h01
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       2 * 3600 + 60)
    }

    func testDailyOvertimeEarlyLeaveIsNegative() {
        // 09:00–16:00 → 6h net → −2h
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 16, 0), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       -2 * 3600)
    }

    func testDailyOvertimeOpenDayBeforeLeaveTimeIsZero() {
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 14, 0), rules: rules), 0)
    }

    func testDailyOvertimeOpenDayAccruesLiveAfterLeaveTime() {
        // leave time 18:01; at 18:31 → +30min
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 18, 31), rules: rules),
                       30 * 60)
    }

    func testFlexReportedNetWinsOverStamps() {
        // Flex says 9h net worked → +1h regardless of stamps
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 10, 0),
                           flexWorkedNet: 9 * 3600)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       1 * 3600)
    }

    func testVeryShortCompletedDayClampsNetAtZero() {
        // 09:00–09:30 gross 30m < 1h break → net 0 → −8h, not −8h30
        let r = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 9, 30), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 6, 23, 0), rules: rules),
                       -8 * 3600)
    }

    func testWeeklyOvertimeCanonical() {
        // Spec canonical: only Monday 09:01–20:02 worked so far → −5h + 2h01 = −2h59
        let mon = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [mon], now: d(2026, 7, 6, 23, 0), rules: rules),
                       -(2 * 3600 + 59 * 60))
    }

    func testWeeklyOvertimeEmptyWeek() {
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [], now: d(2026, 7, 6, 9, 0), rules: rules),
                       -5 * 3600)
    }

    func testWeeklyOvertimeMixedWeek() {
        // Mon +2h01, Tue −1h, Wed open past leave by 10m → −5h + 2h01 − 1h + 10m = −3h49
        let mon = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil)
        let tue = WorkRecord(clockIn: d(2026, 7, 7, 9, 0), clockOut: d(2026, 7, 7, 17, 0), flexWorkedNet: nil)
        let wed = WorkRecord(clockIn: d(2026, 7, 8, 9, 0), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [mon, tue, wed],
                                                     now: d(2026, 7, 8, 18, 10), rules: rules),
                       -(3 * 3600 + 49 * 60))
    }

    func testWeekStartIsMondayMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        // Thu 2026-07-09 → Mon 2026-07-06 00:00
        XCTAssertEqual(WorkCalculator.weekStart(of: d(2026, 7, 9, 14, 0), calendar: cal), d(2026, 7, 6, 0, 0))
        // A Monday maps to itself
        XCTAssertEqual(WorkCalculator.weekStart(of: d(2026, 7, 6, 0, 30), calendar: cal), d(2026, 7, 6, 0, 0))
        // Sunday belongs to the week started the previous Monday
        XCTAssertEqual(WorkCalculator.weekStart(of: d(2026, 7, 12, 23, 0), calendar: cal), d(2026, 7, 6, 0, 0))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `cannot find 'WorkRules' in scope` (etc.).

- [ ] **Step 3: Implement WorkCalculator**

`Sources/FlexTimer/WorkCalculator.swift`:

```swift
import Foundation

struct WorkRules: Codable, Equatable {
    var dailyWork: TimeInterval = 8 * 3600       // net work target per day
    var breakTime: TimeInterval = 1 * 3600       // fixed lunch break
    var weeklyOvertime: TimeInterval = 5 * 3600  // required overtime per week
}

struct WorkRecord: Equatable {
    var clockIn: Date
    var clockOut: Date?                 // nil = still on the clock
    var flexWorkedNet: TimeInterval?    // net worked time as reported by Flex, if available
}

enum WorkCalculator {
    static func leaveTime(clockIn: Date, rules: WorkRules) -> Date {
        clockIn.addingTimeInterval(rules.dailyWork + rules.breakTime)
    }

    static func timeLeft(clockIn: Date, now: Date, rules: WorkRules) -> TimeInterval {
        leaveTime(clockIn: clockIn, rules: rules).timeIntervalSince(now)
    }

    /// Overtime contributed by one record. Completed day: net worked − daily target
    /// (both signs count). Open day: 0 until leave time, then accrues live.
    static func dailyOvertime(record: WorkRecord, now: Date, rules: WorkRules) -> TimeInterval {
        if let out = record.clockOut {
            let net = record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn) - rules.breakTime)
            return net - rules.dailyWork
        }
        return max(0, now.timeIntervalSince(leaveTime(clockIn: record.clockIn, rules: rules)))
    }

    /// Weekly counter: −required + Σ daily overtime. Negative = still owed.
    static func weeklyOvertime(records: [WorkRecord], now: Date, rules: WorkRules) -> TimeInterval {
        records.reduce(-rules.weeklyOvertime) { $0 + dailyOvertime(record: $1, now: now, rules: rules) }
    }

    /// Monday 00:00 of the week containing `date`.
    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)!.start
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all WorkCalculatorTests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: WorkCalculator business math with canonical spec tests"
```

---

### Task 3: Formatting and menu bar text (TDD)

**Files:**

- Create: `Sources/FlexTimer/Formatting.swift`
- Create: `Sources/FlexTimer/DisplayState.swift`
- Test: `Tests/FlexTimerTests/FormattingTests.swift`

**Interfaces:**

- Consumes: `WorkCalculator`, `WorkRecord`, `WorkRules` (Task 2).
- Produces (used by Task 8):
    - `Formatting.hm(_: TimeInterval) -> String` — `"2:34"`, clamps negatives to `"0:00"`
    - `Formatting.signedHM(_: TimeInterval) -> String` — `"-2:59"` / `"+0:12"`
    - `Formatting.hms(_: TimeInterval) -> String` — `"2:34:12"`
    - `enum DisplayState { case noSession, notClockedIn, counting(timeLeft: TimeInterval), overtime(weekly: TimeInterval) }`
    - `DisplayState.compute(hasSession:today:week:now:rules:) -> DisplayState`
    - `DisplayState.menuBarText -> String`

- [ ] **Step 1: Write the failing tests**

`Tests/FlexTimerTests/FormattingTests.swift`:

```swift
import XCTest
@testable import FlexTimer

final class FormattingTests: XCTestCase {
    func testHM() {
        XCTAssertEqual(Formatting.hm(2 * 3600 + 34 * 60 + 59), "2:34") // floors seconds
        XCTAssertEqual(Formatting.hm(5 * 60), "0:05")
        XCTAssertEqual(Formatting.hm(-30), "0:00")
    }

    func testSignedHM() {
        XCTAssertEqual(Formatting.signedHM(-(2 * 3600 + 59 * 60)), "-2:59")
        XCTAssertEqual(Formatting.signedHM(12 * 60), "+0:12")
        XCTAssertEqual(Formatting.signedHM(0), "+0:00")
    }

    func testHMS() {
        XCTAssertEqual(Formatting.hms(2 * 3600 + 34 * 60 + 12), "2:34:12")
    }
}

final class DisplayStateTests: XCTestCase {
    let rules = WorkRules()

    func testNoSession() {
        XCTAssertEqual(DisplayState.compute(hasSession: false, today: nil, week: [],
                                            now: d(2026, 7, 6, 9, 0), rules: rules), .noSession)
        XCTAssertEqual(DisplayState.noSession.menuBarText, "⏳ —")
    }

    func testNotClockedIn() {
        XCTAssertEqual(DisplayState.compute(hasSession: true, today: nil, week: [],
                                            now: d(2026, 7, 6, 8, 0), rules: rules), .notClockedIn)
        XCTAssertEqual(DisplayState.notClockedIn.menuBarText, "⏳ --:--")
    }

    func testCountingDuringDay() {
        let today = WorkRecord(clockIn: d(2026, 7, 6, 8, 59), clockOut: nil, flexWorkedNet: nil)
        let s = DisplayState.compute(hasSession: true, today: today, week: [today],
                                     now: d(2026, 7, 6, 15, 25), rules: rules)
        XCTAssertEqual(s, .counting(timeLeft: 2 * 3600 + 34 * 60))
        XCTAssertEqual(s.menuBarText, "⏳ 2:34")
    }

    func testOvertimeAfterLeaveTime() {
        // Spec canonical Monday evening: shows OT -2:59
        let today = WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: nil, flexWorkedNet: nil)
        let s = DisplayState.compute(hasSession: true, today: today, week: [today],
                                     now: d(2026, 7, 6, 20, 2), rules: rules)
        XCTAssertEqual(s, .overtime(weekly: -(2 * 3600 + 59 * 60)))
        XCTAssertEqual(s.menuBarText, "OT -2:59")
    }

    func testOvertimeAfterClockingOutEarly() {
        // Already clocked out → show weekly OT even if before leave time
        let today = WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 16, 0), flexWorkedNet: nil)
        let s = DisplayState.compute(hasSession: true, today: today, week: [today],
                                     now: d(2026, 7, 6, 16, 5), rules: rules)
        XCTAssertEqual(s, .overtime(weekly: -7 * 3600))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `cannot find 'Formatting' in scope`.

- [ ] **Step 3: Implement**

`Sources/FlexTimer/Formatting.swift`:

```swift
import Foundation

enum Formatting {
    /// "2:34" — floors to whole minutes, clamps negatives to "0:00".
    static func hm(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval)) / 60
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "-2:59" / "+0:12" — explicit sign, zero shown as "+0:00".
    static func signedHM(_ interval: TimeInterval) -> String {
        let m = Int(abs(interval)) / 60
        return (interval < 0 ? "-" : "+") + "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "2:34:12"
    static func hms(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return "\(s / 3600):" + String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
    }
}
```

`Sources/FlexTimer/DisplayState.swift`:

```swift
import Foundation

enum DisplayState: Equatable {
    case noSession
    case notClockedIn
    case counting(timeLeft: TimeInterval)
    case overtime(weekly: TimeInterval)

    /// Smart single value: countdown while on the clock before leave time,
    /// weekly overtime position otherwise.
    static func compute(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                        now: Date, rules: WorkRules) -> DisplayState {
        guard let today else { return hasSession ? .notClockedIn : .noSession }
        let left = WorkCalculator.timeLeft(clockIn: today.clockIn, now: now, rules: rules)
        if today.clockOut == nil && left > 0 { return .counting(timeLeft: left) }
        return .overtime(weekly: WorkCalculator.weeklyOvertime(records: week, now: now, rules: rules))
    }

    var menuBarText: String {
        switch self {
        case .noSession: return "⏳ —"
        case .notClockedIn: return "⏳ --:--"
        case .counting(let left): return "⏳ " + Formatting.hm(left)
        case .overtime(let weekly): return "OT " + Formatting.signedHM(weekly)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: formatting and smart single-value display state"
```

---

### Task 4: CookieVault — Keychain-backed session storage (TDD)

**Files:**

- Create: `Sources/FlexTimer/CookieVault.swift`
- Test: `Tests/FlexTimerTests/CookieVaultTests.swift`

**Interfaces:**

- Consumes: nothing.
- Produces (used by Tasks 6, 7, 8):
    - `struct StoredCookie: Codable, Equatable { name, value, domain, path: String; expires: Date? }` with `init(_ c: HTTPCookie)`
    - `CookieVault.save(_ cookies: [HTTPCookie])`
    - `CookieVault.saveStored(_ cookies: [StoredCookie])`
    - `CookieVault.load() -> [StoredCookie]?`
    - `CookieVault.clear()`
    - `CookieVault.service: String` (mutable, so tests use a throwaway service name)

- [ ] **Step 1: Write the failing test**

`Tests/FlexTimerTests/CookieVaultTests.swift`:

```swift
import XCTest
@testable import FlexTimer

final class CookieVaultTests: XCTestCase {
    override func setUp() {
        CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
    }
    override func tearDown() { CookieVault.clear() }

    func testRoundTripAndClear() {
        let cookies = [
            StoredCookie(name: "SID", value: "abc123", domain: ".flex.team", path: "/", expires: nil),
            StoredCookie(name: "RID", value: "xyz", domain: "flex.team", path: "/", expires: Date(timeIntervalSince1970: 2_000_000_000)),
        ]
        CookieVault.saveStored(cookies)
        XCTAssertEqual(CookieVault.load(), cookies)

        CookieVault.clear()
        XCTAssertNil(CookieVault.load())
    }

    func testSaveOverwrites() {
        CookieVault.saveStored([StoredCookie(name: "A", value: "1", domain: "flex.team", path: "/", expires: nil)])
        CookieVault.saveStored([StoredCookie(name: "B", value: "2", domain: "flex.team", path: "/", expires: nil)])
        XCTAssertEqual(CookieVault.load()?.map(\.name), ["B"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `cannot find 'CookieVault' in scope`.

- [ ] **Step 3: Implement**

`Sources/FlexTimer/CookieVault.swift`:

```swift
import Foundation
import Security

struct StoredCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?

    init(name: String, value: String, domain: String, path: String, expires: Date?) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires
    }

    init(_ c: HTTPCookie) {
        self.init(name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expiresDate)
    }
}

/// Stores the Flex session cookies as one JSON blob in the login Keychain.
enum CookieVault {
    static var service = "com.perso.flextimer.session"
    private static let account = "flex"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ cookies: [HTTPCookie]) {
        saveStored(cookies.map(StoredCookie.init))
    }

    static func saveStored(_ cookies: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> [StoredCookie]? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let cookies = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return nil }
        return cookies
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: all tests PASS. (Keychain tests hit the real login keychain under a throwaway service name; they clean up after themselves.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Keychain-backed cookie vault"
```

---

### Task 5: Flex private API discovery (interactive — requires the user)

**Files:**

- Create: `Sources/FlexTimer/FlexAPIConfig.swift`
- Create: `Tests/FlexTimerTests/Fixtures/week.json`
- Create: `docs/flex-api.md`

**Interfaces:**

- Consumes: nothing.
- Produces (used by Tasks 6, 7):
    - `FlexAPIConfig.loginURL: URL`
    - `FlexAPIConfig.sessionCookieNames: Set<String>` — cookie names that must be present for a session to count as logged-in
    - `FlexAPIConfig.weekRecordsRequest(from: Date, to: Date, cookieHeader: String) -> URLRequest`
    - `Tests/FlexTimerTests/Fixtures/week.json` — a real captured response

**This task cannot be completed without the user.** It is a discovery session, not a coding task. If executing via subagent, this task must run in the main session where the user can respond.

- [ ] **Step 1: Ask the user to capture the API traffic**

Ask the user to do the following (paste these instructions to them):

1. Open Chrome, go to `https://flex.team/time-tracking/my-work-record`, log in if needed.
2. Open DevTools → Network tab → filter `Fetch/XHR`. Reload the page.
3. Find the request(s) whose response contains your daily clock-in/clock-out times for the current week (click through the responses; look for your times like `08:59`).
4. For each such request: right-click → **Copy → Copy as cURL**, and also copy the **response body** (Response tab).
5. Paste both here. Also paste the current page URL and, from the Application tab → Cookies → flex.team, the **names** (not values) of the cookies present.

- [ ] **Step 2: Save the fixture**

Save the pasted response body verbatim as `Tests/FlexTimerTests/Fixtures/week.json` (remove the `.gitkeep` if present). This file contains personal data — it stays in this local repo; do not publish the repo without scrubbing it.

- [ ] **Step 3: Write FlexAPIConfig from the captured cURL**

Extract from the cURL: the endpoint URL and how the date range is encoded (query params, path segments, or POST body), the required headers (e.g. `x-flex-*` headers, `content-type`), and which cookies the request actually sends. Determine the session cookie names by checking which cookies look like auth tokens (long opaque values; typically named like `AID`, `RID`, `SESSION`, or similar — use what is actually there).

Write `Sources/FlexTimer/FlexAPIConfig.swift`. The values below are illustrative — **replace every value with what was actually captured**; keep the signatures exactly:

```swift
import Foundation

enum FlexAPIConfig {
    static let loginURL = URL(string: "https://flex.team/sign-in")!  // use the real login URL observed

    /// Cookie names that must all be present for us to consider the user logged in.
    static let sessionCookieNames: Set<String> = ["AID", "RID"]  // ← replace with captured names

    /// Request that returns work records covering [from, to].
    static func weekRecordsRequest(from: Date, to: Date, cookieHeader: String) -> URLRequest {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"  // ← match the captured date encoding
        df.timeZone = .current
        var comps = URLComponents(string: "https://flex.team/api/.../work-records")!  // ← real endpoint
        comps.queryItems = [
            URLQueryItem(name: "from", value: df.string(from: from)),  // ← real param names
            URLQueryItem(name: "to", value: df.string(from: to)),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"  // ← match capture; if POST, set httpBody accordingly
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // ← add any other headers the capture shows are required (x-* headers etc.)
        return req
    }
}
```

- [ ] **Step 4: Verify the request works outside the browser**

Reconstruct the captured cURL but strip it down to only the endpoint + Cookie header + the headers included in `weekRecordsRequest`, and run it:

Run: `curl -s '<endpoint-with-params>' -H 'Cookie: <captured cookies>' -H 'Accept: application/json' | head -c 500`
Expected: the same JSON shape as the fixture (not an HTML login page). If it returns login HTML or 401, add back captured headers one at a time until it works, and mirror the required set in `weekRecordsRequest`.

- [ ] **Step 5: Document findings**

Write `docs/flex-api.md` recording: the endpoint, method, params, required headers, session cookie names, response shape (annotated sample), and the date the capture was made. This is the map for future breakage repairs.

- [ ] **Step 6: Verify build still passes, commit**

Run: `swift build && swift test`
Expected: builds, existing tests pass.

```bash
git add -A && git commit -m "feat: Flex private API discovery — config, fixture, docs"
```

---

### Task 6: FlexRecordParser + FlexClient (TDD against fixture)

**Files:**

- Create: `Sources/FlexTimer/FlexRecordParser.swift`
- Create: `Sources/FlexTimer/FlexClient.swift`
- Test: `Tests/FlexTimerTests/FlexClientTests.swift`

**Interfaces:**

- Consumes: `FlexAPIConfig` (Task 5), `CookieVault` (Task 4), `WorkRecord` (Task 2), fixture `week.json`.
- Produces (used by Task 8):
    - `FlexRecordParser.parse(_ data: Data) throws -> [WorkRecord]`
    - `final class FlexClient { func fetchWeek(from: Date, to: Date) async throws -> [WorkRecord] }`
    - `FlexClient.FlexError: Error, Equatable — .noSession, .sessionExpired, .badResponse`

- [ ] **Step 1: Write the failing parser test**

The exact assertions depend on the fixture captured in Task 5. Write the test by opening `Tests/FlexTimerTests/Fixtures/week.json`, reading the actual values, and asserting them. The structure is fixed:

`Tests/FlexTimerTests/FlexClientTests.swift`:

```swift
import XCTest
@testable import FlexTimer

final class FlexRecordParserTests: XCTestCase {
    func fixture() throws -> Data {
        let url = Bundle.module.url(forResource: "week", withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    func testParsesFixture() throws {
        let records = try FlexRecordParser.parse(try fixture())
        // Replace the literals below with the true values visible in week.json:
        XCTAssertEqual(records.count, 4)                                   // ← actual day count in fixture
        XCTAssertEqual(records[0].clockIn, d(2026, 7, 6, 8, 59))           // ← actual first clock-in
        XCTAssertEqual(records[0].clockOut, d(2026, 7, 6, 18, 12))         // ← actual first clock-out
        XCTAssertNil(records.last?.clockOut)                                // if fixture's last day is open
    }

    func testGarbageDataThrows() {
        XCTAssertThrowsError(try FlexRecordParser.parse(Data("not json".utf8)))
    }
}
```

Rules for writing this test honestly: every literal must come from reading the fixture by eye. If the fixture has fields for net worked minutes or day-type (vacation/holiday), also assert `flexWorkedNet` for one record — and resolve the spec's open choice: **a day Flex marks as vacation/holiday must be skipped by the parser (contributes nothing to the weekly sum)**.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `cannot find 'FlexRecordParser' in scope`.

- [ ] **Step 3: Implement the parser**

Write `Sources/FlexTimer/FlexRecordParser.swift` with `Codable` structs mirroring the fixture's actual JSON shape, mapping to `[WorkRecord]` sorted by `clockIn`. Skeleton (adjust field names/nesting to the fixture):

```swift
import Foundation

enum FlexRecordParser {
    // Codable structs mirroring the captured response — rename fields to match week.json.
    private struct Response: Decodable { let days: [Day] }
    private struct Day: Decodable {
        let date: String            // e.g. "2026-07-06"
        let clockInAt: String?      // ISO8601 or epoch — match the fixture
        let clockOutAt: String?
        let workedMinutes: Int?     // if Flex reports net worked time
        let dayType: String?        // if Flex marks vacation/holiday days
    }

    static func parse(_ data: Data) throws -> [WorkRecord] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let iso = ISO8601DateFormatter()
        return response.days.compactMap { day -> WorkRecord? in
            if let type = day.dayType, type != "WORK" { return nil }  // skip vacation/holiday
            guard let inStr = day.clockInAt, let clockIn = iso.date(from: inStr) else { return nil }
            return WorkRecord(clockIn: clockIn,
                              clockOut: day.clockOutAt.flatMap(iso.date(from:)),
                              flexWorkedNet: day.workedMinutes.map { TimeInterval($0 * 60) })
        }.sorted { $0.clockIn < $1.clockIn }
    }
}
```

- [ ] **Step 4: Run parser tests to verify they pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Implement FlexClient**

`Sources/FlexTimer/FlexClient.swift`:

```swift
import Foundation

final class FlexClient {
    enum FlexError: Error, Equatable { case noSession, sessionExpired, badResponse }

    private let session: URLSession

    init() {
        // No automatic cookie storage/redirect surprises: we manage cookies ourselves.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func fetchWeek(from: Date, to: Date) async throws -> [WorkRecord] {
        guard let cookies = CookieVault.load(), !cookies.isEmpty else { throw FlexError.noSession }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let request = FlexAPIConfig.weekRecordsRequest(from: from, to: to, cookieHeader: header)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FlexError.badResponse }
        switch http.statusCode {
        case 200:
            // An HTML login page with status 200 also means the session died.
            if let text = String(data: data.prefix(64), encoding: .utf8),
               text.lowercased().contains("<!doctype html") || text.lowercased().hasPrefix("<html") {
                CookieVault.clear()
                throw FlexError.sessionExpired
            }
            return try FlexRecordParser.parse(data)
        case 401, 403:
            CookieVault.clear()
            throw FlexError.sessionExpired
        default:
            throw FlexError.badResponse
        }
    }
}
```

- [ ] **Step 6: Add client behavior tests (no network)**

Append to `Tests/FlexTimerTests/FlexClientTests.swift`:

```swift
final class FlexClientTests: XCTestCase {
    func testFetchWithoutSessionThrowsNoSession() async {
        CookieVault.service = "com.perso.flextimer.test-\(UUID().uuidString)"
        defer { CookieVault.clear() }
        do {
            _ = try await FlexClient().fetchWeek(from: Date(), to: Date())
            XCTFail("expected throw")
        } catch let e as FlexClient.FlexError {
            XCTAssertEqual(e, .noSession)
        } catch { XCTFail("unexpected error \(error)") }
    }
}
```

- [ ] **Step 7: Run tests, verify pass, commit**

Run: `swift test`
Expected: all PASS.

```bash
git add -A && git commit -m "feat: FlexClient and record parser built against captured fixture"
```

- [ ] **Step 8: One-shot live verification**

With the real Keychain session absent (fresh machine state), this can't run — but if Task 5's cookies are still valid, add them once manually for a live check: run the app after Task 8 wiring, or defer this to Task 8's smoke test. Note the choice in the commit message if deferred.

---

### Task 7: Login window — WKWebView cookie capture

**Files:**

- Create: `Sources/FlexTimer/LoginWindowController.swift`

**Interfaces:**

- Consumes: `FlexAPIConfig.loginURL`, `FlexAPIConfig.sessionCookieNames` (Task 5), `CookieVault` (Task 4).
- Produces (used by Task 8): `final class LoginWindowController: NSObject` with `func show(onSuccess: @escaping () -> Void)`. Idempotent: calling `show` while the window is open just brings it to front.

- [ ] **Step 1: Implement**

`Sources/FlexTimer/LoginWindowController.swift`:

```swift
import AppKit
import WebKit

/// Shows the real flex.team login page in a webview; when the session cookies
/// appear, saves them to the CookieVault, closes, and fires onSuccess.
final class LoginWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var onSuccess: (() -> Void)?

    func show(onSuccess: @escaping () -> Void) {
        self.onSuccess = onSuccess
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.load(URLRequest(url: FlexAPIConfig.loginURL))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Sign in to Flex"
        win.contentView = web
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        webView = web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let flexCookies = cookies.filter { $0.domain.contains("flex.team") }
            let names = Set(flexCookies.map(\.name))
            guard FlexAPIConfig.sessionCookieNames.isSubset(of: names) else { return }
            CookieVault.save(flexCookies)
            let done = self.onSuccess
            self.close()
            done?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
    }

    private func close() {
        window?.close()
    }
}
```

- [ ] **Step 2: Verify it compiles and existing tests pass**

Run: `swift build && swift test`
Expected: builds; tests PASS. (The window itself is exercised manually in Task 8's smoke test — no unit test for AppKit/WebKit plumbing.)

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: Flex login window with session cookie capture"
```

---

### Task 8: AppState + menu bar wiring (the app becomes real)

**Files:**

- Create: `Sources/FlexTimer/AppState.swift`
- Create: `Sources/FlexTimer/MenuBarView.swift`
- Modify: `Sources/FlexTimer/FlexTimerApp.swift`
- Test: `Tests/FlexTimerTests/AppStateTests.swift`

**Interfaces:**

- Consumes: everything from Tasks 2–7.
- Produces: `@MainActor final class AppState: ObservableObject` with `@Published var menuText: String`, `@Published var week: [WorkRecord]`, `@Published var lastSync: Date?`, `@Published var syncError: String?`, `@Published var hasSession: Bool`, plus `func start()`, `func refresh() async`, `func signIn()`, `func recompute(now: Date)`, `var rules: WorkRules`, and `var today: WorkRecord?` (computed). Task 9 adds the manual-start hook.

- [ ] **Step 1: Write the failing test for recompute logic**

`Tests/FlexTimerTests/AppStateTests.swift`:

```swift
import XCTest
@testable import FlexTimer

@MainActor
final class AppStateTests: XCTestCase {
    func testRecomputePicksTodayAndSetsMenuText() {
        let state = AppState()
        state.hasSession = true
        state.week = [
            WorkRecord(clockIn: d(2026, 7, 6, 9, 1), clockOut: d(2026, 7, 6, 20, 2), flexWorkedNet: nil),
            WorkRecord(clockIn: d(2026, 7, 7, 8, 59), clockOut: nil, flexWorkedNet: nil),
        ]
        state.recompute(now: d(2026, 7, 7, 15, 25)) // Tuesday 15:25, clocked in 08:59
        XCTAssertEqual(state.menuText, "⏳ 2:34")

        state.recompute(now: d(2026, 7, 7, 19, 0)) // past 17:59 → weekly OT: −5h +2h01 +1h01 = −1:58
        XCTAssertEqual(state.menuText, "OT -1:58")
    }

    func testNoRecordTodayShowsPlaceholder() {
        let state = AppState()
        state.hasSession = true
        state.week = []
        state.recompute(now: d(2026, 7, 7, 8, 0))
        XCTAssertEqual(state.menuText, "⏳ --:--")
    }

    func testNoSessionShowsDash() {
        let state = AppState()
        state.hasSession = false
        state.recompute(now: d(2026, 7, 7, 8, 0))
        XCTAssertEqual(state.menuText, "⏳ —")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: compile error — `cannot find 'AppState' in scope`.

- [ ] **Step 3: Implement AppState**

`Sources/FlexTimer/AppState.swift`:

```swift
import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var menuText = "⏳ --:--"
    @Published var week: [WorkRecord] = []
    @Published var lastSync: Date?
    @Published var syncError: String?
    @Published var hasSession: Bool = CookieVault.load()?.isEmpty == false

    var rules: WorkRules { WorkRules() } // Task 9 replaces this with SettingsStore.rules

    private let client = FlexClient()
    private let login = LoginWindowController()
    private var tickTimer: Timer?
    private var refreshTimer: Timer?

    var today: WorkRecord? {
        week.first { Calendar.current.isDate($0.clockIn, inSameDayAs: Date()) }
    }

    /// Kick off timers and the first fetch. Call once from the App.
    func start() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute(now: Date()) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func recompute(now: Date) {
        let todayRecord = week.first { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }
        let state = DisplayState.compute(hasSession: hasSession, today: todayRecord,
                                         week: week, now: now, rules: rules)
        menuText = state.menuBarText
    }

    func refresh() async {
        do {
            let now = Date()
            week = try await client.fetchWeek(from: WorkCalculator.weekStart(of: now), to: now)
            lastSync = now
            syncError = nil
            hasSession = true
        } catch let e as FlexClient.FlexError where e == .noSession || e == .sessionExpired {
            hasSession = false
        } catch {
            syncError = "Flex sync failed — showing last known data"
        }
        recompute(now: Date())
    }

    func signIn() {
        login.show { [weak self] in
            Task { await self?.refresh() }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS. (`AppStateTests` never calls `start()`, so no timers/network run in tests.)

- [ ] **Step 5: Implement the dropdown view and wire the app**

`Sources/FlexTimer/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let today = state.today {
                row("Started", today.clockIn.formatted(date: .omitted, time: .shortened))
                row("Leave at", WorkCalculator.leaveTime(clockIn: today.clockIn, rules: state.rules)
                    .formatted(date: .omitted, time: .shortened))
                row("Time left", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules)))
            } else if state.hasSession {
                Text("Not clocked in yet").foregroundStyle(.secondary)
            }

            Divider()
            row("Week OT", Formatting.signedHM(WorkCalculator.weeklyOvertime(
                records: state.week, now: Date(), rules: state.rules)))

            if let error = state.syncError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let sync = state.lastSync {
                Text("Synced \(sync.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            if state.hasSession {
                Button("↻ Refresh from Flex") { Task { await state.refresh() } }
            } else {
                Button("Sign in to Flex…") { state.signIn() }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
```

Replace `Sources/FlexTimer/FlexTimerApp.swift` with:

```swift
import SwiftUI

@main
struct FlexTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state: AppState

    init() {
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        Task { @MainActor in s.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            Text(state.menuText)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 6: Live smoke test with the user**

Run: `swift run &`
Expected sequence: menu bar shows `⏳ —` (no session) → dropdown → "Sign in to Flex…" opens the login window → user logs in → window closes itself → within a few seconds the menu bar shows the real countdown (`⏳ H:MM`) and the dropdown shows today's Started/Leave at/Time left plus Week OT matching the user's Flex page. Ask the user to eyeball the numbers against flex.team. Fix parsing discrepancies now, updating fixture assertions if the interpretation was wrong.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: wire menu bar app — live countdown, dropdown, login flow"
```

---

### Task 9: Settings + manual fallback

**Files:**

- Create: `Sources/FlexTimer/SettingsStore.swift`
- Modify: `Sources/FlexTimer/AppState.swift` (rules + manual record)
- Modify: `Sources/FlexTimer/MenuBarView.swift` (manual start-time entry)
- Test: `Tests/FlexTimerTests/SettingsStoreTests.swift`

**Interfaces:**

- Consumes: `WorkRules` (Task 2), `AppState` (Task 8).
- Produces:
    - `SettingsStore.rules: WorkRules` — reads UserDefaults keys `dailyWorkHours` (Double), `breakMinutes` (Double), `weeklyOvertimeHours` (Double); missing keys → spec defaults 8/60/5
    - `SettingsStore.manualStart(on day: Date) -> Date?` / `SettingsStore.setManualStart(_ date: Date?, on day: Date)` — persisted per calendar day, key `manualStart-yyyy-MM-dd`
    - `SettingsStore.defaults: UserDefaults` (mutable for tests)

- [ ] **Step 1: Write the failing tests**

`Tests/FlexTimerTests/SettingsStoreTests.swift`:

```swift
import XCTest
@testable import FlexTimer

final class SettingsStoreTests: XCTestCase {
    override func setUp() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
    }

    func testDefaultRules() {
        XCTAssertEqual(SettingsStore.rules, WorkRules())
    }

    func testOverriddenRules() {
        SettingsStore.defaults.set(7.0, forKey: "dailyWorkHours")
        SettingsStore.defaults.set(30.0, forKey: "breakMinutes")
        SettingsStore.defaults.set(4.0, forKey: "weeklyOvertimeHours")
        XCTAssertEqual(SettingsStore.rules,
                       WorkRules(dailyWork: 7 * 3600, breakTime: 30 * 60, weeklyOvertime: 4 * 3600))
    }

    func testManualStartRoundTripAndClear() {
        let day = d(2026, 7, 9, 0, 0)
        XCTAssertNil(SettingsStore.manualStart(on: day))
        let start = d(2026, 7, 9, 8, 59)
        SettingsStore.setManualStart(start, on: day)
        XCTAssertEqual(SettingsStore.manualStart(on: day), start)
        SettingsStore.setManualStart(nil, on: day)
        XCTAssertNil(SettingsStore.manualStart(on: day))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: compile error — `cannot find 'SettingsStore' in scope`.

- [ ] **Step 3: Implement SettingsStore**

`Sources/FlexTimer/SettingsStore.swift`:

```swift
import Foundation

/// Rules and manual overrides, stored in UserDefaults so they are tweakable
/// without a rebuild (see README for `defaults write` commands).
enum SettingsStore {
    static var defaults = UserDefaults.standard

    static var rules: WorkRules {
        var r = WorkRules()
        if let h = defaults.object(forKey: "dailyWorkHours") as? Double { r.dailyWork = h * 3600 }
        if let m = defaults.object(forKey: "breakMinutes") as? Double { r.breakTime = m * 60 }
        if let h = defaults.object(forKey: "weeklyOvertimeHours") as? Double { r.weeklyOvertime = h * 3600 }
        return r
    }

    private static func key(for day: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "manualStart-" + df.string(from: day)
    }

    static func manualStart(on day: Date) -> Date? {
        defaults.object(forKey: key(for: day)) as? Date
    }

    static func setManualStart(_ date: Date?, on day: Date) {
        if let date { defaults.set(date, forKey: key(for: day)) }
        else { defaults.removeObject(forKey: key(for: day)) }
    }
}
```

- [ ] **Step 4: Wire into AppState**

In `Sources/FlexTimer/AppState.swift`, replace the `rules` property and thread the manual record through `recompute` and `today`:

```swift
    var rules: WorkRules { SettingsStore.rules }

    var today: WorkRecord? {
        todayRecord(now: Date())
    }

    /// Flex record for the day if present, else a synthetic record from manual entry.
    func todayRecord(now: Date) -> WorkRecord? {
        if let flex = week.first(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }) {
            return flex
        }
        if let manual = SettingsStore.manualStart(on: now) {
            return WorkRecord(clockIn: manual, clockOut: nil, flexWorkedNet: nil)
        }
        return nil
    }
```

and in `recompute(now:)` change the first line to use it (named `record`, not `todayRecord` — a local named after the method would shadow it and fail to compile):

```swift
        let record = todayRecord(now: now)
```

(pass `record` as the `today:` argument to `DisplayState.compute`).

**Weekly-sum note:** a manual record is displayed for the countdown but is NOT in `week`, so it would be missing from the weekly OT sum. Fix by computing the week list once in `recompute` and `MenuBarView` via a helper on AppState:

```swift
    /// Week records including the synthetic manual record for today, if any.
    func weekIncludingManual(now: Date) -> [WorkRecord] {
        var records = week
        if !records.contains(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }),
           let manual = todayRecord(now: now) {
            records.append(manual)
        }
        return records
    }
```

Use `weekIncludingManual(now: now)` instead of `week` in `recompute`'s `DisplayState.compute` call, and in `MenuBarView`'s Week OT row.

Add a regression test to `Tests/FlexTimerTests/AppStateTests.swift`:

```swift
    func testManualStartDrivesCountdownAndWeeklySum() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        state.week = []
        let now = d(2026, 7, 9, 15, 25)
        SettingsStore.setManualStart(d(2026, 7, 9, 8, 59), on: now)
        state.recompute(now: now)
        XCTAssertEqual(state.menuText, "⏳ 2:34")
    }
```

- [ ] **Step 5: Add manual entry to the dropdown**

In `Sources/FlexTimer/MenuBarView.swift`, add a manual start section (shown when there's no Flex record for today) and switch the Week OT row to `state.weekIncludingManual(now: Date())`:

```swift
    @State private var manualTime = Date()

    // inside body, in the `else if state.hasSession` branch replacing the plain text:
    VStack(alignment: .leading, spacing: 6) {
        Text("Not clocked in yet").foregroundStyle(.secondary)
        HStack {
            DatePicker("Started at", selection: $manualTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
            Button("Set") {
                SettingsStore.setManualStart(manualTime, on: Date())
                state.recompute(now: Date())
            }
        }
    }
```

- [ ] **Step 6: Run all tests, verify pass**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 7: Manual check**

Run: `swift run &` — in the dropdown before Flex has a record (or with Wi-Fi off), set a manual start time; the menu bar countdown must start from it. Quit the app.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: settings via UserDefaults and manual start-time fallback"
```

---

### Task 10: App bundle, install, README

**Files:**

- Create: `scripts/bundle.sh`
- Create: `README.md`

**Interfaces:**

- Consumes: the built executable.
- Produces: `build/FlexTimer.app` — installable, login-item-ready.

- [ ] **Step 1: Write the bundle script**

`scripts/bundle.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/FlexTimer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/FlexTimer "$APP/Contents/MacOS/FlexTimer"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FlexTimer</string>
  <key>CFBundleIdentifier</key><string>com.perso.flextimer</string>
  <key>CFBundleExecutable</key><string>FlexTimer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "Built $APP — copy to /Applications and add to Login Items."
```

Run: `chmod +x scripts/bundle.sh`

- [ ] **Step 2: Build and verify the bundle**

Run: `./scripts/bundle.sh && open build/FlexTimer.app`
Expected: app launches from the bundle, menu bar item appears with live data (session persists via Keychain — no re-login needed), no Dock icon, no window.

- [ ] **Step 3: Write README**

`README.md` covering: what the app shows (the two display modes with the exact copy), install steps (`./scripts/bundle.sh`, copy to `/Applications`, System Settings → General → Login Items → add FlexTimer), the `defaults write com.perso.flextimer dailyWorkHours -float 8` / `breakMinutes` / `weeklyOvertimeHours` overrides, the manual fallback, a pointer to `docs/flex-api.md` for when Flex changes their API, and the note that the repo contains a personal-data fixture so it must be scrubbed before publishing.

Note: when run unbundled (`swift run`), UserDefaults uses a different domain than `com.perso.flextimer` — document the `defaults write` commands against the bundle id, which applies to the installed app.

- [ ] **Step 4: Final full check and commit**

Run: `swift test && ./scripts/bundle.sh`
Expected: all tests pass, bundle builds.

```bash
git add -A && git commit -m "feat: app bundle script and README"
```
