import Foundation

/// Parsed week: work records plus holiday/vacation weekdays (days whose
/// dayOffs contain a non-weekend-marker entry; weekends themselves excluded).
struct ParseResult: Equatable {
    var records: [WorkRecord]
    var dayOffDates: Set<Date>
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
        let startTimestamp: Timestamp
        let endTimestampExclusive: Timestamp
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

        // Step 1: completed days from work-schedules — one record per day,
        // earliest WORK start to latest WORK end.
        for day in schedules.dailySchedules {
            if let offs = day.dayOffs,
               offs.contains(where: { !weekendMarkers.contains($0.type) }),
               let dayDate = dayFormatter.date(from: day.date),
               (2...6).contains(Calendar.current.component(.weekday, from: dayDate)) {  // Mon–Fri
                dayOffDates.insert(Calendar.current.startOfDay(for: dayDate))
            }
            let workBlocks = day.timeBlocks.filter { $0.type == "WORK" }
            guard !workBlocks.isEmpty else { continue }
            let starts = workBlocks.compactMap { $0.value?.startTimestamp.timestamp }
            let ends = workBlocks.compactMap { $0.value?.endTimestampExclusive.timestamp }
            guard let minStart = starts.min(), let maxEnd = ends.max() else { continue }
            records[day.date] = WorkRecord(clockIn: date(msSince1970: minStart),
                                            clockOut: date(msSince1970: maxEnd),
                                            flexWorkedNet: nil)
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
                           dayOffDates: dayOffDates)
    }
}
