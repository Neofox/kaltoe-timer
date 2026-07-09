# Holiday-Aware Weekly Overtime + Family Day Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deduct 1h from the weekly overtime requirement per holiday/vacation weekday (from Flex `dayOffs` data), and implement family day (last Friday of month): 6h daily target + 1h weekly deduction.

**Architecture:** `FlexRecordParser` starts surfacing weekday day-off dates it currently drops (new `ParseResult` return type). `WorkCalculator` gains `isFamilyDay`/`dailyTarget`/`requiredOvertime`; `leaveTime` and `dailyOvertime` become family-day-aware internally (signatures unchanged — the day derives from `clockIn`), so the countdown and pills adjust automatically. `weeklyOvertime` and `DisplayState.computeDisplay` gain a defaulted `dayOffs: Set<Date> = []` parameter, so existing call sites and tests compile untouched; `AppState`/`MenuBarView` pass the real set.

**Tech Stack:** Swift Package Manager, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-10-holiday-aware-overtime-design.md`

## Global Constraints

- Deduction rule: a Mon–Fri day whose `dayOffs` contains any entry with `type` ∉ {`REST_DAY`, `WEEKLY_HOLIDAY`} is a deduction day (full-day AND half-day both deduct the full amount). Unknown types count.
- Family day = last Friday of the calendar month. Effects: daily target `dailyWork − familyDayEarlyLeave` that day; weekly requirement −`familyDayDeduction` for the week containing it; if family day is itself a day-off, it is excluded from the day-off count (no double deduction). `familyDayEarlyLeave == 0` disables family day entirely (both effects).
- Required weekly overtime floors at 0.
- New `WorkRules` fields (seconds) with defaults: `dayOffDeduction` = 1h, `familyDayEarlyLeave` = 2h, `familyDayDeduction` = 1h. UserDefaults override keys (hours, Double): `dayOffDeductionHours`, `familyDayEarlyLeaveHours`, `familyDayDeductionHours`.
- Manual (offline) entries carry no day-off data; deductions come only from synced Flex data.
- Existing public signatures `leaveTime(clockIn:rules:)`, `dailyOvertime(record:now:rules:)` must NOT change; `weeklyOvertime` gains `dayOffs: Set<Date> = []` as its second parameter (defaulted).
- Calendar facts used by tests: 2026-07-04 = Saturday; 2026-07-31 = last Friday of July 2026; 2026-07-24 = a Friday that is not last; 2026-08-28 = last Friday of August 2026.
- Test style: `d(y,mo,da,h,mi)` helper; per-test `UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!` where defaults are involved.
- `swift test` full suite must pass at every commit. CAUTION: on this Mac an unattended plain `swift test` can hang >5 min on a securityd keychain-consent prompt; if it does, kill it and run under a temporary keychain (capture the original `security list-keychains` list, front a temp keychain, restore and verify login.keychain-db + System.keychain afterward).

---

### Task 1: WorkRules fields + SettingsStore keys (TDD)

**Files:**

- Modify: `Sources/FlexTimer/WorkCalculator.swift:3-10` (WorkRules struct)
- Modify: `Sources/FlexTimer/SettingsStore.swift:8-17` (rules loader)
- Test: `Tests/FlexTimerTests/SettingsStoreTests.swift`

**Interfaces:**

- Produces (later tasks rely on these exact names): `WorkRules.dayOffDeduction`, `WorkRules.familyDayEarlyLeave`, `WorkRules.familyDayDeduction` (all `TimeInterval`, defaults 3600 / 7200 / 3600).

- [ ] **Step 1: Write the failing test**

Add to `Tests/FlexTimerTests/SettingsStoreTests.swift`:

```swift
    func testDefaultHolidayAndFamilyDayRules() {
        let r = SettingsStore.rules
        XCTAssertEqual(r.dayOffDeduction, 1 * 3600)
        XCTAssertEqual(r.familyDayEarlyLeave, 2 * 3600)
        XCTAssertEqual(r.familyDayDeduction, 1 * 3600)
    }

    func testOverriddenHolidayAndFamilyDayRules() {
        SettingsStore.defaults.set(0.5, forKey: "dayOffDeductionHours")
        SettingsStore.defaults.set(0.0, forKey: "familyDayEarlyLeaveHours")
        SettingsStore.defaults.set(2.0, forKey: "familyDayDeductionHours")
        let r = SettingsStore.rules
        XCTAssertEqual(r.dayOffDeduction, 1800)
        XCTAssertEqual(r.familyDayEarlyLeave, 0)
        XCTAssertEqual(r.familyDayDeduction, 2 * 3600)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SettingsStoreTests`
Expected: build error — `value of type 'WorkRules' has no member 'dayOffDeduction'`

- [ ] **Step 3: Implement**

In `Sources/FlexTimer/WorkCalculator.swift`, add to `WorkRules` after `lunchEarlyLeave`:

```swift
    var dayOffDeduction: TimeInterval = 1 * 3600     // weekly-required reduction per holiday/vacation weekday
    var familyDayEarlyLeave: TimeInterval = 2 * 3600 // family-day daily-target reduction; 0 disables family day
    var familyDayDeduction: TimeInterval = 1 * 3600  // weekly-required reduction for a family-day week
```

In `Sources/FlexTimer/SettingsStore.swift`, add to `rules` before `return r`:

```swift
        if let h = defaults.object(forKey: "dayOffDeductionHours") as? Double { r.dayOffDeduction = h * 3600 }
        if let h = defaults.object(forKey: "familyDayEarlyLeaveHours") as? Double { r.familyDayEarlyLeave = h * 3600 }
        if let h = defaults.object(forKey: "familyDayDeductionHours") as? Double { r.familyDayDeduction = h * 3600 }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SettingsStoreTests`
Expected: all pass (existing `testDefaultRules` still passes — new fields have defaults, `WorkRules()` equality unchanged)

Run: `swift test`
Expected: full suite passes

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/WorkCalculator.swift Sources/FlexTimer/SettingsStore.swift Tests/FlexTimerTests/SettingsStoreTests.swift
git commit -m "feat: WorkRules day-off and family-day knobs with defaults overrides"
```

---

### Task 2: WorkCalculator — family day + adjusted requirement (TDD)

**Files:**

- Modify: `Sources/FlexTimer/WorkCalculator.swift` (WorkCalculator enum)
- Test: `Tests/FlexTimerTests/WorkCalculatorTests.swift`

**Interfaces:**

- Consumes: Task 1's `WorkRules` fields.
- Produces (later tasks rely on these exact signatures):
    - `WorkCalculator.isFamilyDay(_ date: Date, calendar: Calendar = .current) -> Bool`
    - `WorkCalculator.dailyTarget(on day: Date, rules: WorkRules, calendar: Calendar = .current) -> TimeInterval`
    - `WorkCalculator.requiredOvertime(dayOffs: Set<Date>, weekOf now: Date, rules: WorkRules, calendar: Calendar = .current) -> TimeInterval`
    - `WorkCalculator.weeklyOvertime(records: [WorkRecord], dayOffs: Set<Date> = [], now: Date, rules: WorkRules) -> TimeInterval` (existing calls without `dayOffs:` keep compiling)
    - `leaveTime(clockIn:rules:)` and `dailyOvertime(record:now:rules:)` unchanged signatures, now family-day-aware.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/FlexTimerTests/WorkCalculatorTests.swift`:

```swift
    // MARK: - Family day

    func testIsFamilyDayLastFridayOnly() {
        XCTAssertTrue(WorkCalculator.isFamilyDay(d(2026, 7, 31, 12, 0)))   // last Friday of July
        XCTAssertTrue(WorkCalculator.isFamilyDay(d(2026, 8, 28, 12, 0)))   // last Friday of August
        XCTAssertFalse(WorkCalculator.isFamilyDay(d(2026, 7, 24, 12, 0)))  // Friday, not last
        XCTAssertFalse(WorkCalculator.isFamilyDay(d(2026, 7, 30, 12, 0)))  // Thursday before it
    }

    func testFamilyDayLeaveTimeIsTwoHoursEarlier() {
        // 09:00 + 6h target + 1h break = 16:00 on family day
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: rules),
                       d(2026, 7, 31, 16, 0))
        // familyDayEarlyLeave = 0 disables it: 09:00 + 8h + 1h = 18:00
        var noFamily = rules
        noFamily.familyDayEarlyLeave = 0
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: noFamily),
                       d(2026, 7, 31, 18, 0))
    }

    func testFamilyDayEarlyLeaveIsFree() {
        // In 09:00, out 16:00 → 7h gross − 1h break = 6h net = family-day target → 0 overtime
        let r = WorkRecord(clockIn: d(2026, 7, 31, 9, 0), clockOut: d(2026, 7, 31, 16, 0), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 31, 23, 0), rules: rules), 0)
    }

    func testFamilyDayOpenRecordAccruesAfterEarlyLeaveTime() {
        // Still clocked in at 16:30 on family day (leave was 16:00) → +30 min
        let r = WorkRecord(clockIn: d(2026, 7, 31, 9, 0), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 7, 31, 16, 30), rules: rules),
                       30 * 60)
    }

    // MARK: - Adjusted weekly requirement

    func testRequiredOvertimePlainWeek() {
        // Week of Mon 2026-07-06: no day-offs, no family day → 5h
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       5 * 3600)
    }

    func testRequiredOvertimeDeductsPerDayOff() {
        let thu = Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))
        let fri = Calendar.current.startOfDay(for: d(2026, 7, 10, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [thu], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       4 * 3600)
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [thu, fri], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       3 * 3600)
    }

    func testRequiredOvertimeIgnoresDayOffsOutsideWeek() {
        let prevWeek = Calendar.current.startOfDay(for: d(2026, 7, 2, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [prevWeek], weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       5 * 3600)
    }

    func testRequiredOvertimeFamilyDayWeek() {
        // Week of Mon 2026-07-27 contains family day Fri 2026-07-31 → 5 − 1 = 4h
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [], weekOf: d(2026, 7, 29, 12, 0), rules: rules),
                       4 * 3600)
    }

    func testFamilyDayVacationCoincidenceDeductsOnce() {
        // Vacation ON family day: family-day −1h applies, day-off count excludes it → 4h, not 3h
        let familyFriday = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [familyFriday], weekOf: d(2026, 7, 29, 12, 0), rules: rules),
                       4 * 3600)
    }

    func testRequiredOvertimeFloorsAtZero() {
        let days = (6...10).map { Calendar.current.startOfDay(for: d(2026, 7, $0, 0, 0)) }
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: Set(days), weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       0)
    }

    func testWeeklyOvertimeUsesAdjustedRequirement() {
        // One day-off Thursday, no records yet → counter = −4:00
        let thu = Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [], dayOffs: [thu],
                                                     now: d(2026, 7, 8, 12, 0), rules: rules),
                       -4 * 3600)
    }
```

Note: this test file already defines `rules` (a `WorkRules()` instance) and `d(...)` at file scope — reuse them; check the top of the file and match whatever the existing tests use (e.g. `let rules = WorkRules()` inside the class or file).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WorkCalculatorTests`
Expected: build error — `type 'WorkCalculator' has no member 'isFamilyDay'`

- [ ] **Step 3: Implement**

In `Sources/FlexTimer/WorkCalculator.swift`, inside `enum WorkCalculator`:

Replace `leaveTime`:

```swift
    static func leaveTime(clockIn: Date, rules: WorkRules) -> Date {
        clockIn.addingTimeInterval(dailyTarget(on: clockIn, rules: rules) + rules.breakTime)
    }
```

Replace the completed-day branch of `dailyOvertime` (the `return net - rules.dailyWork` line) so the whole function reads:

```swift
    /// Overtime contributed by one record. Completed day: net worked − daily target
    /// (both signs count; the target is family-day-aware). Open day: 0 until leave
    /// time, then accrues live.
    static func dailyOvertime(record: WorkRecord, now: Date, rules: WorkRules) -> TimeInterval {
        if let out = record.clockOut {
            let net = record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn) - rules.breakTime)
            return net - dailyTarget(on: record.clockIn, rules: rules)
        }
        return max(0, now.timeIntervalSince(leaveTime(clockIn: record.clockIn, rules: rules)))
    }
```

Replace `weeklyOvertime`:

```swift
    /// Weekly counter: −(adjusted required) + Σ daily overtime. Negative = still owed.
    static func weeklyOvertime(records: [WorkRecord], dayOffs: Set<Date> = [],
                               now: Date, rules: WorkRules) -> TimeInterval {
        records.reduce(-requiredOvertime(dayOffs: dayOffs, weekOf: now, rules: rules)) {
            $0 + dailyOvertime(record: $1, now: now, rules: rules)
        }
    }
```

Add the new functions:

```swift
    /// Family day: the last Friday of the calendar month (disabled when
    /// rules.familyDayEarlyLeave == 0 — callers check that, not this).
    static func isFamilyDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.weekday, from: date) == 6 else { return false } // Friday
        guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: date) else { return false }
        return !calendar.isDate(nextWeek, equalTo: date, toGranularity: .month)   // +7d leaves the month
    }

    /// Net work target for a given day: dailyWork, reduced on family day.
    static func dailyTarget(on day: Date, rules: WorkRules, calendar: Calendar = .current) -> TimeInterval {
        guard rules.familyDayEarlyLeave > 0, isFamilyDay(day, calendar: calendar) else { return rules.dailyWork }
        return rules.dailyWork - rules.familyDayEarlyLeave
    }

    /// Required overtime for the week containing `now`: base − dayOffDeduction per
    /// holiday/vacation weekday − familyDayDeduction if the week contains family day
    /// (family day itself never double-counts as a day-off). Floored at 0.
    static func requiredOvertime(dayOffs: Set<Date>, weekOf now: Date, rules: WorkRules,
                                 calendar: Calendar = .current) -> TimeInterval {
        let start = weekStart(of: now, calendar: calendar)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return rules.weeklyOvertime }
        var required = rules.weeklyOvertime
        var familyDay: Date?
        if rules.familyDayEarlyLeave > 0,
           let friday = calendar.date(byAdding: .day, value: 4, to: start),  // Mon-start week → Friday
           isFamilyDay(friday, calendar: calendar) {
            familyDay = friday
            required -= rules.familyDayDeduction
        }
        let deductionDays = dayOffs
            .filter { $0 >= start && $0 < end }
            .filter { day in familyDay.map { !calendar.isDate(day, inSameDayAs: $0) } ?? true }
        required -= rules.dayOffDeduction * Double(deductionDays.count)
        return max(0, required)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorkCalculatorTests`
Expected: all pass — including the pre-existing tests (their dates are July 6–12, 2026: no family day, no day-offs, so values are unchanged)

Run: `swift test`
Expected: full suite passes (DisplayState/AppState tests use early-July dates, unaffected)

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/WorkCalculator.swift Tests/FlexTimerTests/WorkCalculatorTests.swift
git commit -m "feat: family-day daily target and holiday-adjusted weekly requirement"
```

---

### Task 3: Parser surfaces day-off dates (TDD)

**Files:**

- Modify: `Sources/FlexTimer/FlexRecordParser.swift`
- Modify: `Sources/FlexTimer/FlexClient.swift:16-28` (`fetchWeek` return type)
- Modify: `Tests/FlexTimerTests/Fixtures/sample-schedules.json`
- Test: `Tests/FlexTimerTests/FlexClientTests.swift`

**Interfaces:**

- Consumes: nothing from Tasks 1–2.
- Produces (Task 4 relies on these):
    - `struct ParseResult: Equatable { var records: [WorkRecord]; var dayOffDates: Set<Date> }` (in FlexRecordParser.swift, file scope)
    - `FlexRecordParser.parse(schedules:clock:) throws -> ParseResult`
    - `FlexClient.fetchWeek(from:to:) async throws -> ParseResult`

- [ ] **Step 1: Extend the fixture**

In `Tests/FlexTimerTests/Fixtures/sample-schedules.json`:

1. On the `"2026-07-08"` day (currently `"dayOffs": []`), change to `"dayOffs": [{"type": "TIME_OFF"}]` — a half-day: day-off plus existing WORK blocks.
2. Append a new day after `"2026-07-09"`, inside `dailySchedules`:

```json
, {"date": "2026-07-10", "timezone": "Asia/Seoul", "dayOffs": [{"type": "TIME_OFF"}], "timeBlocks": []}
```

Record counts are unchanged (07-08 keeps its WORK blocks; 07-10 has none), so existing FlexClientTests record assertions still hold after the mechanical `.records` update below.

- [ ] **Step 2: Write the failing tests**

In `Tests/FlexTimerTests/FlexClientTests.swift`:

1. Mechanical update: the five existing `FlexRecordParser.parse(...)` call sites bind `[WorkRecord]`; change each `let records = try FlexRecordParser.parse(...)` to `let records = try FlexRecordParser.parse(...).records` (and the two `XCTAssertThrowsError` sites need no change — they discard the result).
2. Add:

```swift
    func testParseReportsWeekdayDayOffs() throws {
        let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                                clock: try fixture("sample-clock"))
        let expected: Set<Date> = [
            Calendar.current.startOfDay(for: d(2026, 7, 8, 0, 0)),   // half-day: dayOff + WORK blocks
            Calendar.current.startOfDay(for: d(2026, 7, 10, 0, 0)),  // full-day vacation
        ]
        XCTAssertEqual(result.dayOffDates, expected)
        // Weekend markers (REST_DAY 07-04, WEEKLY_HOLIDAY 07-05) are NOT day-offs.
    }
```

(Match the file's existing `fixture(_:)` helper name/signature — check the top of the file.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter FlexClientTests`
Expected: build error — `value of type '[WorkRecord]' has no member 'records'` (or missing `ParseResult`)

- [ ] **Step 4: Implement**

In `Sources/FlexTimer/FlexRecordParser.swift`:

Add at file scope (above the enum):

```swift
/// Parsed week: work records plus holiday/vacation weekdays (days whose
/// dayOffs contain a non-weekend-marker entry; weekends themselves excluded).
struct ParseResult: Equatable {
    var records: [WorkRecord]
    var dayOffDates: Set<Date>
}
```

Add `dayOffs` to `DailySchedule` and a `DayOff` struct:

```swift
    private struct DailySchedule: Decodable {
        let date: String
        let dayOffs: [DayOff]?
        let timeBlocks: [TimeBlock]
    }

    private struct DayOff: Decodable {
        let type: String
    }
```

Add above `parse`:

```swift
    /// Weekend markers observed in the API — these are the weekly rest days,
    /// not vacations/holidays (docs/flex-api.md).
    private static let weekendMarkers: Set<String> = ["REST_DAY", "WEEKLY_HOLIDAY"]

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
```

In `parse`, change the return type to `ParseResult`, and collect day-offs in the existing Step-1 loop over `schedules.dailySchedules` (before the `guard !workBlocks.isEmpty` skip, so half-days are counted). Final shape of the loop and return:

```swift
        var dayOffDates: Set<Date> = []

        for day in schedules.dailySchedules {
            if let offs = day.dayOffs,
               offs.contains(where: { !weekendMarkers.contains($0.type) }),
               let dayDate = dayFormatter.date(from: day.date),
               (2...6).contains(Calendar.current.component(.weekday, from: dayDate)) {  // Mon–Fri
                dayOffDates.insert(Calendar.current.startOfDay(for: dayDate))
            }
            let workBlocks = day.timeBlocks.filter { $0.type == "WORK" }
            guard !workBlocks.isEmpty else { continue }
            // ... existing record-building code unchanged ...
        }

        // ... existing Step 2 (work-clock) loop unchanged ...

        return ParseResult(records: records.values.sorted { $0.clockIn < $1.clockIn },
                           dayOffDates: dayOffDates)
```

In `Sources/FlexTimer/FlexClient.swift`, change `fetchWeek`'s return type from `[WorkRecord]` to `ParseResult` (the body's final `return try FlexRecordParser.parse(...)` already produces it).

This breaks `AppState.refresh()` (assigns to `week: [WorkRecord]`) — fix it minimally IN THIS TASK so the build is green, without adding the new stored property yet (that's Task 4):

```swift
            week = try await client.fetchWeek(from: WorkCalculator.weekStart(of: now), to: now).records
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: full suite passes, including `testParseReportsWeekdayDayOffs`

- [ ] **Step 6: Commit**

```bash
git add Sources/FlexTimer/FlexRecordParser.swift Sources/FlexTimer/FlexClient.swift Sources/FlexTimer/AppState.swift Tests/FlexTimerTests/FlexClientTests.swift Tests/FlexTimerTests/Fixtures/sample-schedules.json
git commit -m "feat: parser surfaces weekday day-off dates from Flex dayOffs"
```

---

### Task 4: Thread day-offs through AppState/Display + README

**Files:**

- Modify: `Sources/FlexTimer/AppState.swift` (new published property, `refresh()`, `recompute(now:)`)
- Modify: `Sources/FlexTimer/DisplayState.swift:24-51` (`computeDisplay`)
- Modify: `Sources/FlexTimer/MenuBarView.swift:40-41` (Week OT row)
- Modify: `README.md` (overtime bullet + Customizing Work Hours)
- Test: `Tests/FlexTimerTests/AppStateTests.swift`

**Interfaces:**

- Consumes: `ParseResult` (Task 3), `weeklyOvertime(records:dayOffs:now:rules:)` and `requiredOvertime` (Task 2).
- Produces: `AppState.dayOffDates: Set<Date>`; `DisplayState.computeDisplay(hasSession:today:week:dayOffs:now:rules:calendar:)` with `dayOffs: Set<Date> = []`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/FlexTimerTests/AppStateTests.swift`:

```swift
    func testDayOffAdjustsWeeklyCounterInMenuText() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        // Mon 2026-07-06 worked 9h net (09:00–19:00 minus 1h break) → +1h; Thursday is a vacation day.
        state.week = [WorkRecord(clockIn: d(2026, 7, 6, 9, 0), clockOut: d(2026, 7, 6, 19, 0), flexWorkedNet: nil)]
        state.dayOffDates = [Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))]
        // Tuesday 19:00, past leave time, no record today → overtime phase shows weekly counter:
        // −(5−1)h + 1h = −3:00
        state.recompute(now: d(2026, 7, 7, 19, 0))
        XCTAssertEqual(state.menuText, "--:--")  // not clocked in today — counter not shown here
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: state.weekIncludingManual(now: d(2026, 7, 7, 19, 0)),
                                                     dayOffs: state.dayOffDates,
                                                     now: d(2026, 7, 7, 19, 0), rules: state.rules),
                       -3 * 3600)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppStateTests/testDayOffAdjustsWeeklyCounterInMenuText`
Expected: build error — `value of type 'AppState' has no member 'dayOffDates'`

- [ ] **Step 3: Implement**

In `Sources/FlexTimer/AppState.swift`:

Next to `@Published var week: [WorkRecord] = []`:

```swift
    @Published var dayOffDates: Set<Date> = []
```

In `refresh()`, replace the fetch line (Task 3 left it as `.records`):

```swift
            let result = try await client.fetchWeek(from: WorkCalculator.weekStart(of: now), to: now)
            week = result.records
            dayOffDates = result.dayOffDates
```

In `recompute(now:)`, pass day-offs through:

```swift
        let display = DisplayState.computeDisplay(hasSession: hasSession, today: record,
                                                  week: weekIncludingManual(now: now),
                                                  dayOffs: dayOffDates,
                                                  now: now, rules: rules)
```

In `Sources/FlexTimer/DisplayState.swift`, add the defaulted parameter to `computeDisplay` and use it at the weekly computation:

```swift
    static func computeDisplay(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                               dayOffs: Set<Date> = [],
                               now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> MenuDisplay {
```

and

```swift
        let weekly = WorkCalculator.weeklyOvertime(records: week, dayOffs: dayOffs, now: now, rules: rules)
```

(The legacy `compute` wrapper at DisplayState.swift:54 forwards without day-offs — leave it; the default covers it.)

In `Sources/FlexTimer/MenuBarView.swift`, update the Week OT row:

```swift
            row("Week OT", Formatting.signedHM(WorkCalculator.weeklyOvertime(
                records: state.weekIncludingManual(now: Date()), dayOffs: state.dayOffDates,
                now: Date(), rules: state.rules)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: full suite passes (existing DisplayState/AppState tests use the `dayOffs` default and early-July dates — unchanged values)

- [ ] **Step 5: Update README**

In README.md:

1. In the **Overtime** menu-bar phase bullet ("It resets to -5:00 every Monday at 00:00 (the 5h weekly overtime target)"), append:

```markdown
The requirement adjusts automatically: each holiday or vacation weekday reported by Flex deducts 1h, and a family-day week (last Friday of the month) deducts another 1h — e.g. a week with one public holiday plus family day requires 3h. On family day itself the daily target is 6h, so the countdown targets leaving 2h early and doing so costs nothing.
```

2. In **Customizing Work Hours**, add to the `defaults write` list (match the existing entries' format):

```markdown
defaults write com.perso.flextimer dayOffDeductionHours -float 1 # weekly-required reduction per holiday/vacation day
defaults write com.perso.flextimer familyDayEarlyLeaveHours -float 2 # family-day early leave; 0 disables family day
defaults write com.perso.flextimer familyDayDeductionHours -float 1 # weekly-required reduction on family-day weeks
```

3. Add one caveat sentence after the overtime bullet edit: offline manual entries carry no holiday data, so fully-offline weeks show the unadjusted requirement.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlexTimer/AppState.swift Sources/FlexTimer/DisplayState.swift Sources/FlexTimer/MenuBarView.swift Tests/FlexTimerTests/AppStateTests.swift README.md
git commit -m "feat: holiday/family-day adjusted weekly overtime in display and menu"
```
