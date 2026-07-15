# Flex Private API — Discovery Notes

**Discovered:** 2026-07-09, from the user's working extractor script
(`docs/flex-extract/flex_work_time_extractor.mjs`, kept locally, untracked —
it was used with a personal session). These are unofficial
endpoints (the same XHR the flex.team web app uses); they can change without
notice. If sync breaks, re-capture with DevTools on
`https://flex.team/time-tracking/my-work-record` and update
`Sources/FlexTimer/FlexAPIConfig.swift` + the fixtures.

## Auth

- Cookie-based. Requests send the browser session cookies in a `Cookie`
  header. Required headers observed working: `accept: application/json`,
  `cookie: <session>`, `user-agent: Mozilla/5.0`.
- Session cookie names (captured 2026-07-09): **`AID`** (auth/session token)
  and **`V2_WS_AID`** (workspace/account context) are the required pair —
  `FlexAPIConfig.sessionCookieNames`. Also present but not sufficient/needed
  for auth: `JSESSIONID`, `DEVICE_ID`, `V2_CUSTOMER_INFO`, `FlexTeam-*`
  (UI prefs), `AMP*`/`_ga*`/`_fbp*`/`intercom-*` (analytics/chat). The app
  stores and sends every flex.team cookie it captures, so over-sending is
  harmless.
- The user is identified by an opaque **userIdHash** appearing in both URLs
  (`FlexAPIConfig.userIdHash`).

## Endpoint 1 — work schedules (completed blocks)

```
GET https://flex.team/api/v3/time-tracking/users/{userIdHash}/work-schedules
    ?from=YYYY-MM-DD&to=YYYY-MM-DD&timezone=Asia%2FSeoul
```

Response (shape used by the app):

```
{ "dailySchedules": [
    { "date": "2026-07-06",
      "timezone": "Asia/Seoul",
      "timeBlocks": [
        { "type": "WORK" | "REST" | ...,
          "value": {
            "startTimestamp": { "timestamp": <epoch ms>, "zoneId": "Asia/Seoul" },
            "endTimestampExclusive": { "timestamp": <epoch ms>, "zoneId": "Asia/Seoul" },
            "eventSource": "...", "eventStatus": "...",
            "approval": { "status": "APPROVED" | ... } } } ] } ] }
```

- `type == "WORK"` blocks carry the day's worked interval(s); `REST` blocks
  are breaks.
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
- Completed (non-ongoing) days come from here.

## Endpoint 2 — work clock (live/ongoing records)

```
GET https://flex.team/api/v2/time-tracking/work-clock/users
    ?userIdHashes={userIdHash}&timeStampFrom=<epoch ms>&timeStampTo=<epoch ms>
```

`timeStampFrom`/`timeStampTo` bound the range in epoch milliseconds
(KST midnights in practice; `to` is exclusive end-of-day).

Response (shape used by the app):

```
{ "records": [
    { "records": [
        { "appliedDate": "2026-07-09",
          "appliedZoneId": "Asia/Seoul",
          "workClockRecordPacks": [
            { "onGoing": true | false,
              "startRecord": { "targetTime": <epoch ms>, "realTime": <epoch ms>,
                               "zoneId": "Asia/Seoul", "recordType": "RECORD" },
              "stopRecord":  { ... } | null,
              "restRecords": [ ... ] } ] } ] } ] }
```

- Prefer `targetTime` over `realTime` (matches the extractor script).
- An `onGoing: true` pack with no `stopRecord` is today's open record.

## Merge strategy (mirrors the extractor script; confirmed against fixtures)

1. Take `WORK` blocks from **work-schedules** with
   `eventSource == "WORK_CLOCK"` as completed `WorkRecord`s
   (`clockIn` = start, `clockOut` = end). Actual recorded work/rest always
   carries `WORK_CLOCK`; requests such as 외근/외출 arrive as `WORK` blocks with
   `eventSource: "NORMAL"` that duplicate clock time and appear even while the
   day is still ongoing — counting them fabricated a completed 3h day and
   masked the real ongoing record (observed 2026-07-15; see
   docs/FLEX_OUTSIDE_WORK_INTEGRATION.md). Blocks without `eventSource` are
   kept for safety. Note this means a request-only day with no clock record
   (e.g. approved 외근 without clocking in) produces no work record.
2. Take `onGoing` packs from **work-clock** as open `WorkRecord`s
   (`clockIn` = start, `clockOut` = nil), skipping dates already covered
   by step 1.
3. Days with no WORK blocks and no ongoing pack — weekends
   (`dayOffs: [{type: REST_DAY | WEEKLY_HOLIDAY}]`), vacations, or simply
   not-yet-worked days — produce no record and contribute 0 to the weekly
   overtime sum (this resolves the spec's open choice on vacation days).

## Fixtures

- `Tests/FlexTimerTests/Fixtures/sample-schedules.json` /
  `sample-clock.json` — synthetic fixtures with the captured response
  SHAPE but fabricated times and a fake userIdHash. Safe to publish.

## userIdHash auto-discovery

`V2_CUSTOMER_INFO` is a client-readable cookie whose (URL-decoded) value is
JSON containing `customerIdHash` and `userIdHash`. After login-window cookie
capture, the app parses it and stores `userIdHash` in UserDefaults
(key `flexUserIdHash`); `FlexAPIConfig.userIdHash` prefers that override and
is empty until the first sign-in (FlexClient treats an empty hash as
no-session). This keeps the app free of any hardcoded personal identifier
and working across workspace/user changes without a code edit.

## Client timeout

`FlexClient` sets `timeoutIntervalForRequest = 15` (seconds), down from
URLSession's 60s default. This was driven by the Linux daemon's need to
guarantee a heartbeat within its 60s cycle, but it intentionally applies on
macOS too: flex.team responds in well under 15s in practice, and a timeout's
failure mode is a benign `syncError` plus retry on the next poll, not a
crash or data loss.
