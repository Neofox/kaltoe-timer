# Flex outside-work integration

This note documents the Flex API behavior observed for a coworker's account
(userIdHash redacted) on 2026-07-15 in the `Asia/Seoul` timezone. It focuses on outside work (`외근`)
and the interaction between work schedules and live clock records.

## Summary

Flex does not return a distinct `OUTSIDE_WORK` time-block type. Outside work is
returned as a normal `WORK` block and is classified by `workFormId`.

For the verified tenant:

| Work form ID | Display name | Meaning      |
| ------------ | ------------ | ------------ |
| `992463`     | `근무`       | Regular work |
| `992465`     | `외근`       | Outside work |

These IDs are tenant-specific. Do not hard-code them in a reusable integration.
Resolve them from the work-form catalog and cache that catalog by customer.

The verified outside-work interval was 08:30-11:30 KST. Its approval was still
`WAITING`, so filtering for approved records would incorrectly remove it.

## Relevant endpoints

### Work schedules

```http
GET /api/v3/time-tracking/users/{userIdHash}/work-schedules
    ?from={YYYY-MM-DD}
    &to={YYYY-MM-DD}
    &timezone=Asia%2FSeoul
```

Use this for finalized work blocks and schedule/request overlays.

### Work-clock records

```http
GET /api/v2/time-tracking/work-clock/users
    ?userIdHashes={userIdHash}
    &timeStampFrom={milliseconds}
    &timeStampTo={milliseconds}
```

Use this for live or ongoing work. `switchRecords` are required to reconstruct
changes between regular work and outside work.

### Work-form catalog

```http
GET /api/v2/work-rule/customers/{customerIdHash}/work-forms
```

Use this to resolve `customerWorkFormId` or `workFormId` to a display name and
other form metadata. Cache the result, but refresh it because administrators can
rename, deactivate, or add forms.

## Verified schedule shape

The outside-work request appeared in `dailySchedules[].timeBlocks[]` as follows:

```json
{
    "date": "2026-07-15",
    "timezone": "Asia/Seoul",
    "timeBlocks": [
        {
            "type": "WORK",
            "value": {
                "startTimestamp": {
                    "zoneId": "Asia/Seoul",
                    "timestamp": 1784071800000
                },
                "endTimestampExclusive": {
                    "zoneId": "Asia/Seoul",
                    "timestamp": 1784082600000
                },
                "workFormId": "992465",
                "eventStatus": "RECORD",
                "eventSource": "NORMAL",
                "approval": {
                    "status": "WAITING"
                },
                "allDay": false
            }
        }
    ]
}
```

Important details:

- `type` is `WORK`, not `OUTSIDE_WORK`.
- `workFormId` carries the classification.
- `eventSource` is `NORMAL`, not `WORK_CLOCK`.
- A `WAITING` approval still represents real data that should be returned to
  the application with its pending status.
- The timestamps resolve to 08:30 and 11:30 in `Asia/Seoul`.

## Verified work-form shape

The form catalog identified `992465` as outside work:

```json
{
    "customerWorkFormId": "992465",
    "display": {
        "name": "외근",
        "icon": {
            "key": "car",
            "color": "pink"
        }
    },
    "type": "WORK",
    "active": true,
    "primary": false,
    "paid": {
        "paidType": "PAID"
    },
    "approval": {
        "enabled": true,
        "requiredMemo": true
    }
}
```

Use the catalog as tenant configuration. The display name and icon are useful
signals, but they are editable presentation fields. For stable automation,
store the selected outside-work form ID in tenant configuration after resolving
or confirming it from the catalog.

```ts
const formsById = new Map(response.workForms.map((form: any) => [form.customerWorkFormId, form]))

const outsideWorkFormIds = new Set([tenantConfig.outsideWorkFormId])

function classifyWorkForm(workFormId: string | null) {
    if (workFormId && outsideWorkFormIds.has(workFormId)) return "outside_work"

    const form = workFormId ? formsById.get(workFormId) : null
    return form?.primary ? "regular_work" : "other_work"
}
```

## Verified live clock shape

The same day was still ongoing. Flex returned one clock pack with form switches:

```json
{
    "appliedDate": "2026-07-15",
    "workClockRecordPacks": [
        {
            "startRecord": {
                "eventType": "START",
                "targetTime": 1784071080000,
                "customerWorkFormId": "992463",
                "recordType": "RECORD",
                "zoneId": "Asia/Seoul"
            },
            "switchRecords": [
                {
                    "eventType": "SWITCH",
                    "targetTime": 1784071800000,
                    "customerWorkFormId": "992465",
                    "recordType": "PLAN_BY_WORK_SCHEDULE",
                    "zoneId": "Asia/Seoul"
                },
                {
                    "eventType": "SWITCH",
                    "targetTime": 1784082600000,
                    "customerWorkFormId": "992463",
                    "recordType": "PLAN_BY_WORK_SCHEDULE",
                    "zoneId": "Asia/Seoul"
                }
            ],
            "restRecords": [],
            "onGoing": true
        }
    ]
}
```

This reconstructs to:

| Start | End               | Work form | Classification        |
| ----- | ----------------- | --------- | --------------------- |
| 08:18 | 08:30             | `992463`  | Regular work          |
| 08:30 | 11:30             | `992465`  | Outside work          |
| 11:30 | Current/stop time | `992463`  | Regular work, ongoing |

## Recommended normalization

Normalize both APIs into interval records with explicit provenance:

```ts
type WorkInterval = {
    date: string
    startMs: number
    endMs: number | null
    timezone: string
    workFormId: string | null
    workFormName: string | null
    category: "regular_work" | "outside_work" | "other_work"
    approvalStatus: string | null
    ongoing: boolean
    source: "schedule" | "clock"
}
```

Do not identify intervals by `(date, arrayIndex)`. Array indexes from the two
endpoints are unrelated and collide easily.

Prefer stable source identifiers when available:

- Schedule: `metadata.referenceId`, `workRecordEventId`, or `approvalId`.
- Clock: start, switch, stop, and rest record IDs.
- Normalized segments: `{userId}:{date}:{startMs}:{endMs}:{workFormId}:{source}`.

## Clock segmentation

The clock pack starts with the form on `startRecord`. Each switch closes the
current segment and starts another segment with the switch's form.

```ts
type ClockSegment = {
    startMs: number
    endMs: number
    workFormId: string | null
}

function segmentClockPack(pack: any, nowMs: number): ClockSegment[] {
    const start = pack.startRecord?.targetTime ?? pack.startRecord?.realTime
    if (start == null) return []

    const events = [...(pack.switchRecords ?? [])]
        .filter((event) => event.targetTime != null)
        .sort((a, b) => a.targetTime - b.targetTime)

    const stop = pack.stopRecord?.targetTime ?? pack.stopRecord?.realTime ?? (pack.onGoing ? nowMs : null)

    let cursor = start
    let workFormId = pack.startRecord?.customerWorkFormId ?? null
    const segments: ClockSegment[] = []

    for (const event of events) {
        if (event.targetTime > cursor) {
            segments.push({ startMs: cursor, endMs: event.targetTime, workFormId })
        }
        cursor = event.targetTime
        workFormId = event.customerWorkFormId ?? workFormId
    }

    if (stop != null && stop > cursor) {
        segments.push({ startMs: cursor, endMs: stop, workFormId })
    }

    return segments
}
```

Adapt the returned fields to the application's normalized type and process
`restRecords` separately so breaks are not counted as paid work.

## Reconciliation rules

Schedule blocks and clock segments can overlap. Do not sum both blindly.

1. For completed days, use schedule `WORK` blocks as the canonical finalized
   intervals when they contain complete start and end timestamps.
2. For an ongoing clock pack, reconstruct actual intervals from the clock pack,
   including all `switchRecords`.
3. Match an overlapping schedule block to a clock segment by date, form ID, and
   timestamp overlap. Attach its approval and event metadata to the clock
   segment instead of creating a second duration.
4. Preserve pending or rejected approval states. Whether they count toward an
   approved payroll total is a separate business rule from whether the interval
   exists.
5. Keep the timezone from the record. Do not assume the server or device
   timezone matches the employee's applied timezone.

## Cause of the current extractor bug

The existing extractor records schedule rows under this key:

```js
;`${day.date}:${index}`
```

It then skips an ongoing clock pack when the same date/index key exists:

```js
if (!pack.onGoing || rowsByDate.has(`${day.appliedDate}:${index}`)) continue;
```

On 2026-07-15, schedule block index `0` was the 08:30-11:30 outside-work
request, while clock pack index `0` contained the actual ongoing work timeline.
The key collision discarded the entire clock pack. The extractor also omitted
`workFormId`, so the surviving schedule row could not be identified as outside
work.

The fix should:

- Include `work_form_id`, `work_form_name`, and normalized `work_category`.
- Resolve forms through the work-form catalog.
- Expand `switchRecords` into individual clock segments.
- Reconcile overlapping schedule and clock intervals by identity and overlap,
  not by date/index.
- Keep `approval_status`, including `WAITING`.

## Suggested test cases

1. Ongoing regular work with no switches.
2. Regular work -> outside work -> regular work in one ongoing clock pack.
3. Outside-work schedule block with `approval.status = WAITING`.
4. Finalized outside-work block with no live clock pack.
5. Schedule block and clock segment representing the same interval.
6. Multiple work forms on the same date with identical array indexes across
   endpoints.
7. Rest records inside regular or outside work.
8. Renamed or inactive outside-work form in the tenant catalog.
9. Missing work-form catalog entry: retain the raw form ID and classify it as
   `other_work` instead of dropping the interval.

## Authentication note

These endpoints require an authenticated Flex session. Keep session material in
secret storage, never commit cookie values to fixtures, logs, source control, or
this document. Raw JSON fixtures should contain response bodies only and should
be reviewed for user and approval identifiers before sharing.
