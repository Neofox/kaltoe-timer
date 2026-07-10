# Time-Off Blocks (Half/Full-Day Leave) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse Flex personal-leave timeBlocks (half-day and full-day) so daily targets, leave times, and the weekly requirement reflect approved time off — and fix the decode crash on full-day vacations.

**Architecture:** `FlexRecordParser` gains generic time-off detection (shape-based, not type-name-based) emitting a per-day `timeOff: [Date: TimeInterval]` ledger plus full-day dates merged into the existing `dayOffDates`. `WorkCalculator` reduces the daily target by the day's off-seconds, drops the lunch break when the reduced target is a half-day or less, and deducts the full `dayOffDeduction` for any time-off day. Completed days additionally get `flexWorkedNet` computed from actual WORK−REST blocks.

**Tech Stack:** Swift (SPM, macOS), XCTest. Spec: `docs/superpowers/specs/2026-07-10-timeoff-blocks-design.md`.

## Global Constraints

- Time-off detection is by SHAPE, never by `type` name: `value.usedMinutes > 0 && value.approval?.status == "APPROVED"` (observed types `ANNUAL_TIME_OFF`, `FORBIDDEN_TIME_OFF`; more exist).
- Full-day leave blocks (`allDay: true`) carry NO `startTimestamp`/`endTimestampExclusive` — the decoder must not require them.
- Break rule: full `rules.breakTime` when the reduced daily target > `rules.dailyWork / 2` (i.e. > 4h at defaults), otherwise 0.
- Weekly requirement: any day with approved time off (half or full) deducts the full `dayOffDeduction`; family day never double-counts; floor at 0.
- All date-keyed sets/maps use `Calendar.current.startOfDay`-normalized keys (existing `dayOffDates` convention). Only Mon–Fri dates enter `dayOffDates`/`timeOff`.
- Run tests via `scripts/run-tests-tempkeychain.sh` (created in Task 1). Plain unattended `swift test` hangs on a securityd keychain-consent prompt — if a run stalls >5 min, kill it; do not wait.
- Existing behavior for days without time off must not change, EXCEPT completed schedule days now carry `flexWorkedNet` (actual rest instead of the assumed 1h break) — this is the in-scope accuracy bonus.

---

### Task 1: Parser — decoder resilience + time-off ledger

**Files:**

- Create: `scripts/run-tests-tempkeychain.sh`
- Create: `Tests/FlexTimerTests/Fixtures/sample-schedules-timeoff.json`
- Modify: `Sources/FlexTimer/FlexRecordParser.swift`
- Modify: `docs/flex-api.md`
- Test: `Tests/FlexTimerTests/FlexClientTests.swift` (FlexRecordParserTests class)

**Interfaces:**

- Consumes: existing `FlexRecordParser.parse(schedules:clock:) throws -> ParseResult`, `WorkRecord`.
- Produces: `ParseResult` gains `var timeOff: [Date: TimeInterval] = [:]` (seconds of approved partial time off per startOfDay-normalized weekday). Full-day leave dates appear in the existing `dayOffDates`. Task 5 reads `result.timeOff`.

- [ ] **Step 1: Create the test-runner script**

Write `scripts/run-tests-tempkeychain.sh` (then `chmod +x` it):

```bash
#!/bin/bash
# swift test hangs when run unattended: each rebuilt unsigned test binary
# triggers a securityd keychain-consent prompt (CookieVault uses the login
# keychain). Run the suite against a throwaway default keychain instead.
set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN="${TMPDIR:-/tmp}/flextimer-tests-$$.keychain-db"
ORIGINAL_LIST=$(security list-keychains -d user | sed 's/^ *"//;s/"$//')
ORIGINAL_DEFAULT=$(security default-keychain -d user | sed 's/^ *"//;s/"$//')

cleanup() {
  # shellcheck disable=SC2086
  security list-keychains -d user -s $ORIGINAL_LIST
  security default-keychain -d user -s "$ORIGINAL_DEFAULT"
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
}
trap cleanup EXIT

security create-keychain -p tests "$KEYCHAIN"
security unlock-keychain -p tests "$KEYCHAIN"
# Temp keychain must be BOTH first in the search list and the default:
# SecItemAdd writes to the default while SecItemCopyMatching searches the list.
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $ORIGINAL_LIST
security default-keychain -d user -s "$KEYCHAIN"

swift test "$@"
```

Verify baseline: `scripts/run-tests-tempkeychain.sh` → all existing tests PASS. Afterward confirm restoration: `security list-keychains -d user` shows login.keychain-db + System.keychain again.

- [ ] **Step 2: Create the time-off fixture**

`Tests/FlexTimerTests/Fixtures/sample-schedules-timeoff.json` — scrubbed shapes from real 2026-07-10 captures (timestamps are KST; 2026-01-01 Thu, 2026-01-02 Fri, 2025-11-24 Mon, 2026-03-01 Sun):

```json
{
    "userIdHash": "SAMPLEUSER0",
    "dailySchedules": [
        { "date": "2026-01-01", "timezone": "Asia/Seoul", "dayOffs": [{ "type": "CUSTOM_HOLIDAY" }], "timeBlocks": [] },
        {
            "date": "2026-01-02",
            "timezone": "Asia/Seoul",
            "dayOffs": [],
            "timeBlocks": [
                {
                    "type": "WORK",
                    "value": {
                        "startTimestamp": { "zoneId": "Asia/Seoul", "timestamp": 1767311700000 },
                        "endTimestampExclusive": { "zoneId": "Asia/Seoul", "timestamp": 1767324600000 },
                        "eventStatus": "RECORD",
                        "eventSource": "WORK_CLOCK",
                        "allDay": false
                    }
                },
                {
                    "type": "REST",
                    "value": {
                        "startTimestamp": { "zoneId": "Asia/Seoul", "timestamp": 1767321000000 },
                        "endTimestampExclusive": { "zoneId": "Asia/Seoul", "timestamp": 1767324600000 },
                        "eventStatus": "RECORD",
                        "eventSource": "WORK_CLOCK",
                        "allDay": false
                    }
                },
                {
                    "type": "ANNUAL_TIME_OFF",
                    "value": {
                        "allDay": false,
                        "timezoneAtRegistration": "Asia/Seoul",
                        "startTimestamp": { "zoneId": "Asia/Seoul", "timestamp": 1767324600000 },
                        "endTimestampExclusive": { "zoneId": "Asia/Seoul", "timestamp": 1767339000000 },
                        "status": "APPROVAL_COMPLETED",
                        "timeOffRegisterUnit": "HALF_DAY_PM",
                        "restMinutes": 0,
                        "usedMinutes": 240,
                        "usedPaidMinutes": 240,
                        "approval": { "status": "APPROVED" }
                    }
                }
            ]
        },
        {
            "date": "2025-11-24",
            "timezone": "Asia/Seoul",
            "dayOffs": [],
            "timeBlocks": [
                {
                    "type": "FORBIDDEN_TIME_OFF",
                    "value": {
                        "allDay": true,
                        "timezoneAtRegistration": "Asia/Seoul",
                        "timeOffEventId": "0000000",
                        "status": "APPROVAL_COMPLETED",
                        "memo": "",
                        "timeOffRegisterUnit": "DAY",
                        "restMinutes": 0,
                        "usedMinutes": 480,
                        "usedPaidMinutes": 480,
                        "approval": { "approvalId": "x", "status": "APPROVED" },
                        "cancelApprovals": [],
                        "metadata": { "referenceId": "0000000" }
                    }
                }
            ],
            "approvals": [{ "category": "TIME_OFF", "status": "APPROVED" }],
            "legalTimeBlocks": []
        },
        {
            "date": "2026-03-01",
            "timezone": "Asia/Seoul",
            "dayOffs": [{ "type": "WEEKLY_HOLIDAY" }, { "type": "CUSTOM_HOLIDAY" }],
            "timeBlocks": []
        },
        {
            "date": "2026-03-02",
            "timezone": "Asia/Seoul",
            "dayOffs": [],
            "timeBlocks": [
                {
                    "type": "ANNUAL_TIME_OFF",
                    "value": {
                        "allDay": false,
                        "timezoneAtRegistration": "Asia/Seoul",
                        "startTimestamp": { "zoneId": "Asia/Seoul", "timestamp": 1772416200000 },
                        "endTimestampExclusive": { "zoneId": "Asia/Seoul", "timestamp": 1772430600000 },
                        "status": "APPROVAL_PENDING",
                        "timeOffRegisterUnit": "HALF_DAY_PM",
                        "restMinutes": 0,
                        "usedMinutes": 240,
                        "usedPaidMinutes": 240,
                        "approval": { "status": "PENDING" }
                    }
                }
            ]
        }
    ]
}
```

Register the fixture: check `Package.swift` — the test target already copies the `Fixtures` directory as a resource (existing fixtures load via `Bundle.module`); a new file in that directory needs no Package.swift change. Confirm by building.

- [ ] **Step 3: Write the failing tests**

Append to `FlexRecordParserTests` in `Tests/FlexTimerTests/FlexClientTests.swift`:

```swift
// MARK: - Time-off blocks (docs/superpowers/specs/2026-07-10-timeoff-blocks-design.md)

private var emptyClock: Data { Data("{\"records\":[]}".utf8) }

func testFullDayTimeOffBlockDecodesAndJoinsDayOffDates() throws {
    // FORBIDDEN_TIME_OFF has no startTimestamp — decoding must not throw (regression).
    let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                            clock: emptyClock)
    XCTAssertTrue(result.dayOffDates.contains(Calendar.current.startOfDay(for: d(2025, 11, 24, 0, 0))),
                  "allDay time-off block must count as a full weekday off")
}

func testHalfDayProducesTimeOffSeconds() throws {
    let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                            clock: emptyClock)
    let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
    XCTAssertEqual(result.timeOff[friday], 240 * 60)
    XCTAssertFalse(result.dayOffDates.contains(friday), "half-day is not a full day off")
}

func testHalfDayStillProducesWorkRecord() throws {
    let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                             clock: emptyClock).records
    let rec = records.first { Calendar.current.isDate($0.clockIn, inSameDayAs: d(2026, 1, 2, 12, 0)) }
    XCTAssertEqual(rec?.clockIn, d(2026, 1, 2, 8, 55))
    XCTAssertEqual(rec?.clockOut, d(2026, 1, 2, 12, 30))
}

func testHolidayAndWeekendMarkersOnTimeOffFixture() throws {
    let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                            clock: emptyClock)
    // Weekday CUSTOM_HOLIDAY (Thu 2026-01-01) is a day off.
    XCTAssertTrue(result.dayOffDates.contains(Calendar.current.startOfDay(for: d(2026, 1, 1, 0, 0))))
    // Sunday with WEEKLY_HOLIDAY + CUSTOM_HOLIDAY is NOT (weekday filter).
    XCTAssertFalse(result.dayOffDates.contains(Calendar.current.startOfDay(for: d(2026, 3, 1, 0, 0))))
}

func testUnapprovedTimeOffIgnored() throws {
    let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                            clock: emptyClock)
    let monday = Calendar.current.startOfDay(for: d(2026, 3, 2, 0, 0))
    XCTAssertNil(result.timeOff[monday], "PENDING approval must not count")
    XCTAssertFalse(result.dayOffDates.contains(monday))
}

func testExistingFixtureHasNoTimeOffEntries() throws {
    let result = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                            clock: try fixture("sample-clock"))
    XCTAssertTrue(result.timeOff.isEmpty)
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `scripts/run-tests-tempkeychain.sh --filter FlexRecordParserTests`
Expected: compile FAILURE — `ParseResult` has no member `timeOff` (and after adding it, `testFullDayTimeOffBlockDecodesAndJoinsDayOffDates` fails with a decode error `keyNotFound startTimestamp`).

- [ ] **Step 5: Implement**

In `Sources/FlexTimer/FlexRecordParser.swift`:

Change `ParseResult`:

```swift
/// Parsed week: work records, holiday/vacation weekdays, and per-day
/// approved partial time off (seconds). Weekends excluded from both.
struct ParseResult: Equatable {
    var records: [WorkRecord]
    var dayOffDates: Set<Date>
    var timeOff: [Date: TimeInterval] = [:]
}
```

Change the decode structs (timestamps optional; time-off fields added):

```swift
    private struct TimeBlockValue: Decodable {
        let startTimestamp: Timestamp?
        let endTimestampExclusive: Timestamp?
        let allDay: Bool?
        let usedMinutes: Int?
        let approval: Approval?
    }

    private struct Approval: Decodable {
        let status: String?
    }
```

Replace the schedules loop body (Step 1 section) of `parse(schedules:clock:)`:

```swift
        var records: [String: WorkRecord] = [:]  // keyed by date string, for dedupe against clock.json
        var dayOffDates: Set<Date> = []
        var timeOff: [Date: TimeInterval] = [:]

        // Step 1: completed days from work-schedules — one record per day,
        // earliest WORK start to latest WORK end.
        for day in schedules.dailySchedules {
            let dayDate = dayFormatter.date(from: day.date)
            let isWeekday = dayDate.map { (2...6).contains(Calendar.current.component(.weekday, from: $0)) } ?? false

            if let offs = day.dayOffs,
               offs.contains(where: { !weekendMarkers.contains($0.type) }),
               let dayDate, isWeekday {
                dayOffDates.insert(Calendar.current.startOfDay(for: dayDate))
            }

            // Personal leave arrives as time blocks, not dayOffs. Type names vary
            // (ANNUAL_TIME_OFF, FORBIDDEN_TIME_OFF, ...) so match on shape:
            // usedMinutes + APPROVED. Full-day blocks carry no timestamps.
            if let dayDate, isWeekday {
                let key = Calendar.current.startOfDay(for: dayDate)
                for block in day.timeBlocks {
                    guard let v = block.value, let minutes = v.usedMinutes, minutes > 0,
                          v.approval?.status == "APPROVED" else { continue }
                    if v.allDay == true {
                        dayOffDates.insert(key)
                    } else {
                        timeOff[key, default: 0] += TimeInterval(minutes) * 60
                    }
                }
            }

            let workBlocks = day.timeBlocks.filter { $0.type == "WORK" }
            guard !workBlocks.isEmpty else { continue }
            let starts = workBlocks.compactMap { $0.value?.startTimestamp?.timestamp }
            let ends = workBlocks.compactMap { $0.value?.endTimestampExclusive?.timestamp }
            guard let minStart = starts.min(), let maxEnd = ends.max() else { continue }
            records[day.date] = WorkRecord(clockIn: date(msSince1970: minStart),
                                            clockOut: date(msSince1970: maxEnd),
                                            flexWorkedNet: nil)
        }
```

And the return:

```swift
        return ParseResult(records: records.values.sorted { $0.clockIn < $1.clockIn },
                           dayOffDates: dayOffDates,
                           timeOff: timeOff)
```

Update the doc comment on `FlexRecordParser` if it still says dayOffs-only.

- [ ] **Step 6: Run tests to verify they pass**

Run: `scripts/run-tests-tempkeychain.sh`
Expected: ALL tests PASS (new ones plus the full existing suite — `testParseReportsWeekdayDayOffs` must still pass unchanged).

- [ ] **Step 7: Update docs/flex-api.md**

In the Endpoint 1 section, document the discovered shapes (captured 2026-07-10):

```markdown
- Personal leave is a `timeBlocks[]` entry, NOT a `dayOffs[]` entry. Observed
  types: `ANNUAL_TIME_OFF` (half-day: `allDay: false`,
  `timeOffRegisterUnit: "HALF_DAY_AM"|"HALF_DAY_PM"`, `usedMinutes: 240`,
  real start/end timestamps) and `FORBIDDEN_TIME_OFF` (full day:
  `allDay: true`, `timeOffRegisterUnit: "DAY"`, `usedMinutes: 480`,
  **no timestamps**). Type names vary — the parser matches on shape:
  `usedMinutes > 0` + `approval.status == "APPROVED"`.
- `dayOffs[]` only carries holiday/weekend markers: `CUSTOM_HOLIDAY`
  (public/company holiday), `WEEKLY_HOLIDAY` (usually Sunday), `REST_DAY`
  (usually Saturday). A date can carry several (e.g. 2026-03-01:
  WEEKLY_HOLIDAY + CUSTOM_HOLIDAY).
```

- [ ] **Step 8: Commit**

```bash
git add scripts/run-tests-tempkeychain.sh Tests/FlexTimerTests/Fixtures/sample-schedules-timeoff.json Tests/FlexTimerTests/FlexClientTests.swift Sources/FlexTimer/FlexRecordParser.swift docs/flex-api.md
git commit -m "feat: parse Flex time-off blocks into per-day ledger; survive full-day leave shape"
```

---

### Task 2: Parser — flexWorkedNet from WORK−REST blocks

**Files:**

- Modify: `Sources/FlexTimer/FlexRecordParser.swift` (the WORK-blocks section written in Task 1 Step 5)
- Test: `Tests/FlexTimerTests/FlexClientTests.swift`

**Interfaces:**

- Consumes: Task 1's parse loop.
- Produces: completed-day `WorkRecord.flexWorkedNet` = Σ WORK durations − Σ (REST ∩ WORK) in seconds. `WorkCalculator.dailyOvertime` already prefers `flexWorkedNet` when non-nil — no calculator change needed here.

- [ ] **Step 1: Write the failing tests**

Append to `FlexRecordParserTests`:

```swift
func testFlexWorkedNetComputedFromWorkMinusRest() throws {
    // Existing fixture 07-01: WORK 09:00–19:00 (10h), REST 1h → net 9h.
    let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                             clock: try fixture("sample-clock")).records
    XCTAssertEqual(records[0].flexWorkedNet, 9 * 3600)
}

func testFlexWorkedNetOnHalfDay() throws {
    // 2026-01-02: WORK 08:55–12:30 (3h35m), REST 11:30–12:30 (1h) → net 2h35m.
    let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules-timeoff"),
                                             clock: emptyClock).records
    let rec = records.first { Calendar.current.isDate($0.clockIn, inSameDayAs: d(2026, 1, 2, 12, 0)) }
    XCTAssertEqual(rec?.flexWorkedNet, 2 * 3600 + 35 * 60)
}

func testOngoingClockRecordHasNilFlexWorkedNet() throws {
    let records = try FlexRecordParser.parse(schedules: try fixture("sample-schedules"),
                                             clock: try fixture("sample-clock")).records
    XCTAssertNil(records[6].flexWorkedNet, "open day from work-clock has no net yet")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/run-tests-tempkeychain.sh --filter FlexRecordParserTests`
Expected: the two new flexWorkedNet tests FAIL (nil instead of value); ongoing-nil test PASSES already.

- [ ] **Step 3: Implement**

Replace the WORK-blocks section from Task 1 Step 5 with:

```swift
            let workIntervals: [(start: Int64, end: Int64)] = day.timeBlocks
                .filter { $0.type == "WORK" }
                .compactMap { b in
                    guard let s = b.value?.startTimestamp?.timestamp,
                          let e = b.value?.endTimestampExclusive?.timestamp else { return nil }
                    return (s, e)
                }
            guard let minStart = workIntervals.map(\.start).min(),
                  let maxEnd = workIntervals.map(\.end).max() else { continue }
            let grossMs = workIntervals.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
            let restMs = day.timeBlocks
                .filter { $0.type == "REST" }
                .reduce(Int64(0)) { total, b in
                    guard let s = b.value?.startTimestamp?.timestamp,
                          let e = b.value?.endTimestampExclusive?.timestamp else { return total }
                    // Only the portion overlapping WORK intervals counts as deducted rest.
                    return total + workIntervals.reduce(0) { $0 + max(0, min(e, $1.end) - max(s, $1.start)) }
                }
            records[day.date] = WorkRecord(clockIn: date(msSince1970: minStart),
                                            clockOut: date(msSince1970: maxEnd),
                                            flexWorkedNet: TimeInterval(grossMs - restMs) / 1000)
```

- [ ] **Step 4: Run the full suite**

Run: `scripts/run-tests-tempkeychain.sh`
Expected: ALL PASS. (Existing tests assert only clockIn/clockOut on parsed records; AppState tests build records manually with nil net — unaffected.)

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/FlexRecordParser.swift Tests/FlexTimerTests/FlexClientTests.swift
git commit -m "feat: compute flexWorkedNet from actual WORK/REST blocks"
```

---

### Task 3: Calculator — time-off-aware daily target, break rule, leave time

**Files:**

- Modify: `Sources/FlexTimer/WorkCalculator.swift`
- Test: `Tests/FlexTimerTests/WorkCalculatorTests.swift`

**Interfaces:**

- Consumes: nothing new (pure functions).
- Produces (Task 4 and 5 rely on these exact signatures; all new params defaulted so existing call sites compile unchanged):
    - `WorkCalculator.timeOff(on day: Date, in map: [Date: TimeInterval], calendar: Calendar = .current) -> TimeInterval`
    - `WorkCalculator.breakDuration(target: TimeInterval, rules: WorkRules) -> TimeInterval`
    - `WorkCalculator.dailyTarget(on day: Date, rules: WorkRules, timeOff: TimeInterval = 0, calendar: Calendar = .current) -> TimeInterval`
    - `WorkCalculator.leaveTime(clockIn: Date, rules: WorkRules, timeOff: TimeInterval = 0) -> Date`
    - `WorkCalculator.timeLeft(clockIn: Date, now: Date, rules: WorkRules, timeOff: TimeInterval = 0) -> TimeInterval`
    - `WorkCalculator.dailyOvertime(record: WorkRecord, now: Date, rules: WorkRules, timeOff: [Date: TimeInterval] = [:]) -> TimeInterval`

- [ ] **Step 1: Write the failing tests**

Append to `WorkCalculatorTests`:

```swift
    // MARK: - Time off (half/full-day leave)

    func testHalfDayLeaveTimeHasNoLunchBreak() {
        // 4h off → 4h target → 08:55 + 4h, no break (reduced target ≤ dailyWork/2)
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 1, 2, 8, 55), rules: rules,
                                                timeOff: 4 * 3600),
                       d(2026, 1, 2, 12, 55))
    }

    func testSmallTimeOffKeepsLunchBreak() {
        // 2h off → 6h target > 4h → break stays: 09:00 + 6h + 1h = 16:00
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 6, 9, 0), rules: rules,
                                                timeOff: 2 * 3600),
                       d(2026, 7, 6, 16, 0))
    }

    func testCompletedHalfDayOvertimeAgainstReducedTarget() {
        // Net 2h35m (from Flex) vs 4h target → −1h25m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: d(2026, 1, 2, 12, 30),
                           flexWorkedNet: 2 * 3600 + 35 * 60)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 23, 0), rules: rules,
                                                    timeOff: [friday: 4 * 3600]),
                       -(1 * 3600 + 25 * 60))
    }

    func testCompletedHalfDayFallbackNetSkipsBreak() {
        // No flexWorkedNet: net = gross (no break at ≤4h target). 09:00–12:30 = 3h30m vs 4h → −30m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 9, 0), clockOut: d(2026, 1, 2, 12, 30), flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 23, 0), rules: rules,
                                                    timeOff: [friday: 4 * 3600]),
                       -30 * 60)
    }

    func testOpenHalfDayAccruesAfterReducedLeaveTime() {
        // Leave 12:55; still on the clock at 13:25 → +30m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let r = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: nil, flexWorkedNet: nil)
        XCTAssertEqual(WorkCalculator.dailyOvertime(record: r, now: d(2026, 1, 2, 13, 25), rules: rules,
                                                    timeOff: [friday: 4 * 3600]),
                       30 * 60)
    }

    func testFamilyDayPlusTimeOffStacksAndFloorsAtZero() {
        // Family day 2026-07-31: 8h − 2h family − 4h off = 2h target; 09:00 + 2h = 11:00, no break
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: rules,
                                                timeOff: 4 * 3600),
                       d(2026, 7, 31, 11, 0))
        // 8h off on family day → floor at 0 target → leave = clockIn
        XCTAssertEqual(WorkCalculator.leaveTime(clockIn: d(2026, 7, 31, 9, 0), rules: rules,
                                                timeOff: 8 * 3600),
                       d(2026, 7, 31, 9, 0))
    }

    func testTimeOffLookupNormalizesToStartOfDay() {
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        XCTAssertEqual(WorkCalculator.timeOff(on: d(2026, 1, 2, 14, 33), in: [friday: 4 * 3600]),
                       4 * 3600)
        XCTAssertEqual(WorkCalculator.timeOff(on: d(2026, 1, 3, 14, 33), in: [friday: 4 * 3600]), 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/run-tests-tempkeychain.sh --filter WorkCalculatorTests`
Expected: compile FAILURE (no `timeOff:` parameters, no `WorkCalculator.timeOff`).

- [ ] **Step 3: Implement**

In `Sources/FlexTimer/WorkCalculator.swift`, replace `leaveTime`, `timeLeft`, `dailyOvertime`, `dailyTarget` and add the two helpers:

```swift
    static func leaveTime(clockIn: Date, rules: WorkRules, timeOff: TimeInterval = 0) -> Date {
        let target = dailyTarget(on: clockIn, rules: rules, timeOff: timeOff)
        return clockIn.addingTimeInterval(target + breakDuration(target: target, rules: rules))
    }

    static func timeLeft(clockIn: Date, now: Date, rules: WorkRules, timeOff: TimeInterval = 0) -> TimeInterval {
        leaveTime(clockIn: clockIn, rules: rules, timeOff: timeOff).timeIntervalSince(now)
    }

    /// The day's break: full lunch normally; none when approved time off cuts
    /// the target to a half day or less (per policy: a 4h half-day has no lunch).
    static func breakDuration(target: TimeInterval, rules: WorkRules) -> TimeInterval {
        target > rules.dailyWork / 2 ? rules.breakTime : 0
    }

    /// Approved time-off seconds for the day containing `day` (0 if none).
    /// `map` keys must be `startOfDay`-normalized (parser convention).
    static func timeOff(on day: Date, in map: [Date: TimeInterval],
                        calendar: Calendar = .current) -> TimeInterval {
        map[calendar.startOfDay(for: day)] ?? 0
    }

    /// Overtime contributed by one record. Completed day: net worked − daily target
    /// (both signs count; the target is family-day- and time-off-aware). Open day:
    /// 0 until leave time, then accrues live.
    static func dailyOvertime(record: WorkRecord, now: Date, rules: WorkRules,
                              timeOff: [Date: TimeInterval] = [:]) -> TimeInterval {
        let off = Self.timeOff(on: record.clockIn, in: timeOff)
        let target = dailyTarget(on: record.clockIn, rules: rules, timeOff: off)
        if let out = record.clockOut {
            let net = record.flexWorkedNet
                ?? max(0, out.timeIntervalSince(record.clockIn) - breakDuration(target: target, rules: rules))
            return net - target
        }
        return max(0, now.timeIntervalSince(leaveTime(clockIn: record.clockIn, rules: rules, timeOff: off)))
    }

    /// Net work target for a given day: dailyWork, reduced on family day, then
    /// reduced by approved time off; floored at 0.
    static func dailyTarget(on day: Date, rules: WorkRules, timeOff: TimeInterval = 0,
                            calendar: Calendar = .current) -> TimeInterval {
        var target = rules.dailyWork
        if rules.familyDayEarlyLeave > 0, isFamilyDay(day, calendar: calendar) {
            target -= rules.familyDayEarlyLeave
        }
        return max(0, target - timeOff)
    }
```

- [ ] **Step 4: Run the full suite**

Run: `scripts/run-tests-tempkeychain.sh`
Expected: ALL PASS (defaulted params keep every existing test green).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/WorkCalculator.swift Tests/FlexTimerTests/WorkCalculatorTests.swift
git commit -m "feat: time-off-aware daily target, leave time, and break rule"
```

---

### Task 4: Calculator — weekly requirement merges time-off days

**Files:**

- Modify: `Sources/FlexTimer/WorkCalculator.swift` (`requiredOvertime`, `weeklyOvertime`)
- Test: `Tests/FlexTimerTests/WorkCalculatorTests.swift`

**Interfaces:**

- Consumes: Task 3's `dailyOvertime(record:now:rules:timeOff:)`.
- Produces (Task 5 relies on these):
    - `WorkCalculator.requiredOvertime(dayOffs: Set<Date>, timeOff: [Date: TimeInterval] = [:], weekOf now: Date, rules: WorkRules, calendar: Calendar = .current) -> TimeInterval`
    - `WorkCalculator.weeklyOvertime(records: [WorkRecord], dayOffs: Set<Date> = [], timeOff: [Date: TimeInterval] = [:], now: Date, rules: WorkRules) -> TimeInterval`

- [ ] **Step 1: Write the failing tests**

Append to `WorkCalculatorTests`:

```swift
    func testRequiredOvertimeDeductsFullHourPerTimeOffDay() {
        // Half-day Thursday deducts the FULL dayOffDeduction (policy decision)
        let thu = Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [], timeOff: [thu: 4 * 3600],
                                                       weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       4 * 3600)
    }

    func testRequiredOvertimeMergesTimeOffAndHolidayDays() {
        // Holiday Thursday + half-day Friday → 5 − 1 − 1 = 3h
        let thu = Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))
        let fri = Calendar.current.startOfDay(for: d(2026, 7, 10, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [thu], timeOff: [fri: 4 * 3600],
                                                       weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       3 * 3600)
    }

    func testRequiredOvertimeSameDayHolidayAndTimeOffDeductsOnce() {
        let thu = Calendar.current.startOfDay(for: d(2026, 7, 9, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [thu], timeOff: [thu: 4 * 3600],
                                                       weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       4 * 3600)
    }

    func testRequiredOvertimeHalfDayOnFamilyDayNoDoubleCount() {
        // Half-day ON family day (2026-07-31): family −1h only → 4h
        let familyFriday = Calendar.current.startOfDay(for: d(2026, 7, 31, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [], timeOff: [familyFriday: 4 * 3600],
                                                       weekOf: d(2026, 7, 29, 12, 0), rules: rules),
                       4 * 3600)
    }

    func testRequiredOvertimeIgnoresTimeOffOutsideWeek() {
        let prevWeek = Calendar.current.startOfDay(for: d(2026, 7, 2, 0, 0))
        XCTAssertEqual(WorkCalculator.requiredOvertime(dayOffs: [], timeOff: [prevWeek: 4 * 3600],
                                                       weekOf: d(2026, 7, 8, 12, 0), rules: rules),
                       5 * 3600)
    }

    func testWeeklyOvertimeThreadsTimeOffThroughDailySum() {
        // Half-day Fri completed with net 2h35m vs 4h target (−1h25m);
        // required = 5 − 1 = 4h → weekly = −4h − 1h25m = −5h25m
        let friday = Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0))
        let fri = WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: d(2026, 1, 2, 12, 30),
                             flexWorkedNet: 2 * 3600 + 35 * 60)
        XCTAssertEqual(WorkCalculator.weeklyOvertime(records: [fri], timeOff: [friday: 4 * 3600],
                                                     now: d(2026, 1, 2, 23, 0), rules: rules),
                       -(5 * 3600 + 25 * 60))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/run-tests-tempkeychain.sh --filter WorkCalculatorTests`
Expected: compile FAILURE (no `timeOff:` parameter on `requiredOvertime`/`weeklyOvertime`).

- [ ] **Step 3: Implement**

Replace `weeklyOvertime` and `requiredOvertime` in `WorkCalculator.swift`:

```swift
    /// Weekly counter: −(adjusted required) + Σ daily overtime. Negative = still owed.
    /// `dayOffs`/`timeOff` keys must be `Calendar.current.startOfDay`-normalized dates —
    /// week-range filtering compares instants.
    static func weeklyOvertime(records: [WorkRecord], dayOffs: Set<Date> = [],
                               timeOff: [Date: TimeInterval] = [:],
                               now: Date, rules: WorkRules) -> TimeInterval {
        records.reduce(-requiredOvertime(dayOffs: dayOffs, timeOff: timeOff, weekOf: now, rules: rules)) {
            $0 + dailyOvertime(record: $1, now: now, rules: rules, timeOff: timeOff)
        }
    }

    /// Required overtime for the week containing `now`: base − dayOffDeduction per
    /// holiday/vacation weekday and per day with any approved time off (half or
    /// full — policy: full deduction either way) − familyDayDeduction if the week
    /// contains family day (family day itself never double-counts). Floored at 0.
    /// `dayOffs`/`timeOff` keys must be `Calendar.current.startOfDay`-normalized dates —
    /// week-range filtering compares instants.
    static func requiredOvertime(dayOffs: Set<Date>, timeOff: [Date: TimeInterval] = [:],
                                 weekOf now: Date, rules: WorkRules,
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
        let deductionDays = dayOffs.union(timeOff.keys)
            .filter { $0 >= start && $0 < end }
            .filter { day in familyDay.map { !calendar.isDate(day, inSameDayAs: $0) } ?? true }
        required -= rules.dayOffDeduction * Double(deductionDays.count)
        return max(0, required)
    }
```

- [ ] **Step 4: Run the full suite**

Run: `scripts/run-tests-tempkeychain.sh`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlexTimer/WorkCalculator.swift Tests/FlexTimerTests/WorkCalculatorTests.swift
git commit -m "feat: weekly requirement deducts full hour per approved time-off day"
```

---

### Task 5: Threading — AppState, DisplayState, MenuBarView

**Files:**

- Modify: `Sources/FlexTimer/AppState.swift`
- Modify: `Sources/FlexTimer/DisplayState.swift`
- Modify: `Sources/FlexTimer/MenuBarView.swift`
- Test: `Tests/FlexTimerTests/AppStateTests.swift`

**Interfaces:**

- Consumes: Task 1's `ParseResult.timeOff`; Tasks 3–4's calculator signatures.
- Produces: `AppState.timeOff: [Date: TimeInterval]` (@Published); `DisplayState.computeDisplay(hasSession:today:week:dayOffs:timeOff:now:rules:calendar:)` with `timeOff: [Date: TimeInterval] = [:]`.

- [ ] **Step 1: Write the failing test**

Append to `AppStateTests`:

```swift
    func testHalfDayDrivesReducedCountdownAndWeeklySum() {
        SettingsStore.defaults = UserDefaults(suiteName: "flextimer-tests-\(UUID().uuidString)")!
        let state = AppState()
        state.hasSession = true
        // Half-day Friday 2026-01-02, clocked in 08:55, 4h off → leave 12:55 (no lunch
        // in the leave-time math; 12:35 is past the lunch-phase window, so the menu
        // shows the plain countdown).
        state.week = [WorkRecord(clockIn: d(2026, 1, 2, 8, 55), clockOut: nil, flexWorkedNet: nil)]
        state.timeOff = [Calendar.current.startOfDay(for: d(2026, 1, 2, 0, 0)): 4 * 3600]

        state.recompute(now: d(2026, 1, 2, 12, 35))
        XCTAssertEqual(state.menuText, "0:20")

        // Past 12:55 → overtime phase; weekly = −(5−1)h + accrued 5m = −3:55
        state.recompute(now: d(2026, 1, 2, 13, 0))
        XCTAssertEqual(state.menuText, "OT -3:55")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/run-tests-tempkeychain.sh --filter AppStateTests`
Expected: compile FAILURE — `AppState` has no member `timeOff`.

- [ ] **Step 3: Implement**

`AppState.swift`:

- Add below `@Published var dayOffDates`:

```swift
    @Published var timeOff: [Date: TimeInterval] = [:]
```

- In `recompute(now:)`, pass it through:

```swift
        let display = DisplayState.computeDisplay(hasSession: hasSession, today: record,
                                                  week: weekIncludingManual(now: now),
                                                  dayOffs: dayOffDates,
                                                  timeOff: timeOff,
                                                  now: now, rules: rules)
```

- In `refresh()`, after `dayOffDates = result.dayOffDates`:

```swift
            timeOff = result.timeOff
```

`DisplayState.swift` — new parameter and lookups:

```swift
    static func computeDisplay(hasSession: Bool, today: WorkRecord?, week: [WorkRecord],
                               dayOffs: Set<Date> = [],
                               timeOff: [Date: TimeInterval] = [:],
                               now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> MenuDisplay {
        guard hasSession else { return MenuDisplay(state: .noSession, urgency: .normal) }
        guard let today else { return MenuDisplay(state: .notClockedIn, urgency: .normal) }
        let off = WorkCalculator.timeOff(on: today.clockIn, in: timeOff, calendar: calendar)
        let left = WorkCalculator.timeLeft(clockIn: today.clockIn, now: now, rules: rules, timeOff: off)
        if today.clockOut == nil && left > 0 {
            let lunch = WorkCalculator.lunchWindow(on: now, rules: rules, calendar: calendar)
            let leave = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules, timeOff: off)
            if leave > lunch.endAt { // lunch phases only apply to a normally-shaped day
                if now < lunch.leaveAt {
                    return MenuDisplay(state: .toLunch(timeLeft: lunch.leaveAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
                if now < lunch.endAt {
                    return MenuDisplay(state: .onBreak(timeLeft: lunch.endAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
            }
            let urgency: Urgency = left <= criticalThreshold ? .critical
                : left <= warningThreshold ? .warning : .normal
            return MenuDisplay(state: .counting(timeLeft: left), urgency: urgency)
        }
        let weekly = WorkCalculator.weeklyOvertime(records: week, dayOffs: dayOffs,
                                                   timeOff: timeOff, now: now, rules: rules)
        // Past leave time with the day still open = overworking right now.
        return MenuDisplay(state: .overtime(weekly: weekly),
                           urgency: today.clockOut == nil ? .critical : .normal)
    }
```

(The `compute` v1 wrapper stays as is — defaults cover it.)

Note: a HALF_DAY_PM day whose no-lunch leave still lands after 12:30 (e.g. 08:55 start → 12:55) will show the lunch phases; that mirrors reality (the captured half-day did record an 11:30–12:30 REST) — leave-time math is unaffected either way.

`MenuBarView.swift` — thread today's off-seconds and the weekly map:

```swift
            if let today = state.today, state.hasSession {
                let off = WorkCalculator.timeOff(on: today.clockIn, in: state.timeOff)
                row("Started", today.clockIn.formatted(date: .omitted, time: .shortened))
                row("Leave at", WorkCalculator.leaveTime(clockIn: today.clockIn, rules: state.rules,
                                                         timeOff: off)
                    .formatted(date: .omitted, time: .shortened))
                row("Time left", Formatting.hms(WorkCalculator.timeLeft(
                    clockIn: today.clockIn, now: Date(), rules: state.rules, timeOff: off)))
            } else if state.hasSession {
```

and:

```swift
            row("Week OT", Formatting.signedHM(WorkCalculator.weeklyOvertime(
                records: state.weekIncludingManual(now: Date()), dayOffs: state.dayOffDates,
                timeOff: state.timeOff, now: Date(), rules: state.rules)))
```

- [ ] **Step 4: Run the full suite**

Run: `scripts/run-tests-tempkeychain.sh`
Expected: ALL PASS.

- [ ] **Step 5: Build the app to confirm the UI target compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/FlexTimer/AppState.swift Sources/FlexTimer/DisplayState.swift Sources/FlexTimer/MenuBarView.swift Tests/FlexTimerTests/AppStateTests.swift
git commit -m "feat: thread per-day time off through display, menu, and weekly counter"
```
