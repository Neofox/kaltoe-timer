import Foundation

/// Parsed week: work records, holiday/vacation weekdays, and per-day
/// approved partial time off (seconds). Weekends excluded from both.
struct ParseResult: Equatable {
    var records: [WorkRecord]
    var dayOffDates: Set<Date>
    var timeOff: [Date: TimeInterval] = [:]
}

/// Parses and merges the two Flex endpoints into `[WorkRecord]`.
/// See docs/flex-api.md for the response shapes and merge strategy.
enum FlexRecordParser {
    // MARK: - work-schedules (Endpoint 1: completed WORK/REST blocks)

    private struct SchedulesResponse: Decodable {
        let dailySchedules: [DailySchedule]
    }

    private struct DailySchedule: Decodable {
        let date: String
        let dayOffs: [DayOff]?
        let timeBlocks: [TimeBlock]
    }

    private struct DayOff: Decodable {
        let type: String
    }

    private struct TimeBlock: Decodable {
        let type: String
        let value: TimeBlockValue?
    }

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

    private struct Timestamp: Decodable {
        let timestamp: Int64
    }

    // MARK: - work-clock (Endpoint 2: live/ongoing records)

    private struct ClockResponse: Decodable {
        let records: [ClockUserRecords]
    }

    private struct ClockUserRecords: Decodable {
        let records: [ClockDayRecord]
    }

    private struct ClockDayRecord: Decodable {
        let appliedDate: String
        let workClockRecordPacks: [WorkClockRecordPack]
    }

    private struct WorkClockRecordPack: Decodable {
        let onGoing: Bool
        let startRecord: StartRecord?
    }

    private struct StartRecord: Decodable {
        let targetTime: Int64?
        let realTime: Int64?
    }

    // MARK: - Parsing

    private static func date(msSince1970 ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// Weekend markers observed in the API — these are the weekly rest days,
    /// not vacations/holidays (docs/flex-api.md).
    private static let weekendMarkers: Set<String> = ["REST_DAY", "WEEKLY_HOLIDAY"]

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    static func parse(schedules schedulesData: Data, clock clockData: Data) throws -> ParseResult {
        let schedules = try JSONDecoder().decode(SchedulesResponse.self, from: schedulesData)
        let clock = try JSONDecoder().decode(ClockResponse.self, from: clockData)

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
                                            flexWorkedNet: TimeInterval(max(0, grossMs - restMs)) / 1000)
        }

        // Step 2: ongoing days from work-clock, skipping dates already covered by step 1.
        for userRecords in clock.records {
            for day in userRecords.records {
                guard records[day.appliedDate] == nil else { continue }
                guard let pack = day.workClockRecordPacks.first(where: { $0.onGoing }) else { continue }
                guard let start = pack.startRecord,
                      let startMs = start.targetTime ?? start.realTime else { continue }
                records[day.appliedDate] = WorkRecord(clockIn: date(msSince1970: startMs),
                                                        clockOut: nil,
                                                        flexWorkedNet: nil)
            }
        }

        return ParseResult(records: records.values.sorted { $0.clockIn < $1.clockIn },
                           dayOffDates: dayOffDates,
                           timeOff: timeOff)
    }
}
