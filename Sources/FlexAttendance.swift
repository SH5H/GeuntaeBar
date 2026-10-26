import Foundation

enum FlexDates {
    static let timeZone = TimeZone(identifier: "Asia/Seoul")!
    static var calendar: Calendar { calendar(in: timeZone) }
    static func calendar(in zone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = zone
        return result
    }
    static func parse(_ value: String) throws -> Date {
        let zoned = value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil
        let formatter = ISO8601DateFormatter()
        let text = zoned ? value : value + "+09:00"
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: text) else { throw FlexError.invalidData("근무 기록의 날짜·시각 형식을 읽지 못했습니다.") }
        return date
    }
    static func timestamp(_ milliseconds: Double) throws -> Date {
        guard milliseconds.isFinite, (0...253402214400000).contains(milliseconds) else { throw FlexError.invalidData("근무 기록의 시각이 허용 범위를 벗어났습니다.") }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    static func key(_ date: Date, in zone: TimeZone = timeZone) -> String { String(iso(date, in: zone).prefix(10)) }
    static func iso(_ date: Date, in zone: TimeZone = timeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.string(from: date)
    }
    static func day(_ key: String, in zone: TimeZone = timeZone) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar(in: zone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: key), formatter.string(from: date) == key else { throw FlexError.invalidData("근무 기록의 날짜 형식을 읽지 못했습니다.") }
        return date
    }
    static func ranges(from start: Date, through end: Date, in zone: TimeZone = timeZone) -> [(String, String)] {
        var ranges: [(String, String)] = []
        var cursor = start
        while cursor <= end {
            let last = min(end, calendar(in: zone).date(byAdding: .day, value: 30, to: cursor)!)
            ranges.append((key(cursor, in: zone), key(last, in: zone)))
            cursor = calendar(in: zone).date(byAdding: .day, value: 1, to: last)!
        }
        return ranges
    }
}

struct FlexIdentity: Decodable {
    struct Workspace: Decodable {
        struct User: Decodable { let userIdHash: String; let customerIdHash: String }
        let user: User
    }
    let currentUser: Workspace
}
struct FlexPeriodResponse: Decodable { let period: FlexPeriod }
struct FlexPeriod: Decodable {
    let from: String
    let to: String
    let zoneId: String
    let applyTimeRangeFrom: Int64
    let applyTimeRangeTo: Int64
}
struct FlexPeriodSummary: Decodable {
    struct Result: Decodable {
        struct Period: Decodable { let from: Int64; let to: Int64 }
        let period: Period
        let timezone: String
        let currentTargetWorkingMinutes: Int
        let totalRecognizedWorkingMinutes: Int
        let totalOverWorkingMinutes: Int
        let requiredAgreedWorkingMinutes: Int
        let requiredMaxStatutoryWorkingMinutes: Int?
    }
    let userIdHash: String
    let result: Result
}
struct FlexDailySummary: Decodable {
    let totalActualWorkingMinutes: Int
    let totalRecognizedWorkingMinutes: Int
}
struct FlexServerTime: Decodable { let timeStamp: Double }
struct FlexClockEvent: Decodable, Hashable {
    let eventType: String
    let targetTime: Double
    let recordType: String
}
struct FlexClockPack: Decodable {
    struct Rest: Decodable {
        let restStartRecord: FlexClockEvent
        let restStopRecord: FlexClockEvent?
    }
    let startRecord: FlexClockEvent
    let stopRecord: FlexClockEvent?
    let switchRecords: [FlexClockEvent]
    let restRecords: [Rest]
    let onGoing: Bool
}
struct FlexClockStatus: Decodable {
    struct OnTime: Decodable {
        struct ClockOut: Decodable { let clockOnTime: Double? }
        let clockOutOnTimeInfo: ClockOut?
    }
    let targetDate: String
    let appliedZoneId: String
    let requestedAt: Double
    let onGoingRecordPack: FlexClockPack?
    let onTimeInfo: OnTime?
}
struct FlexDayOff: Decodable { let type: String; let name: String? }
struct FlexSchedule: Decodable {
    struct Block: Decodable, Hashable {
        struct Value: Decodable, Hashable {
            struct Timestamp: Decodable, Hashable { let timestamp: Double }
            let startTimestamp: Timestamp?
            let endTimestampExclusive: Timestamp?
            let eventStatus: String?
            let allDay: Bool?
            let usedMinutes: Int?
            let timeOffRegisterUnit: String?
        }
        let type: String
        let value: Value
    }
    let date: String
    let dayOffs: [FlexDayOff]
    let timeBlocks: [Block]
}
struct FlexSchedules: Decodable { let userIdHash: String; let dailySchedules: [FlexSchedule] }
struct FlexDayAttribute: Decodable {
    struct TimeRange: Decodable { let start: String; let endInclusive: String; let dayPassed: Bool }
    let date: String
    let timezone: String
    let dateType: String
    let dayOffs: [FlexDayOff]
    let usualWorkingMinutes: Int
    let coreTime: TimeRange?
    let recommendedRestTimeRanges: [TimeRange]
}
struct FlexDayAttributes: Decodable { let workingDayAttributes: [FlexDayAttribute] }
struct FlexUserRule: Decodable {
    struct Rule: Decodable { let customerWorkRuleId: String }
    let workRule: Rule
}
struct FlexRules: Decodable { let workRules: [FlexRule] }
struct FlexRule: Decodable {
    let customerWorkRuleId: String
    let baseAgreedDayWorkingMinutes: Int
}

struct CustomHolidayRule: Codable, Equatable {
    var weekday: Int // Calendar weekday, 1 = Sunday
    var ordinals: Set<Int> // n-th occurrence of the weekday in its month, 1...5
    // Which monthly figures the holiday lowers.
    var affectsRequired = true
    var affectsMaximum = true
    var affectsCompensation = true

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        calendar.component(.weekday, from: date) == weekday &&
            ordinals.contains((calendar.component(.day, from: date) - 1) / 7 + 1)
    }
}

extension CustomHolidayRule {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekday = try container.decode(Int.self, forKey: .weekday)
        ordinals = try container.decode(Set<Int>.self, forKey: .ordinals)
        // Rules saved before these options existed keep the original behavior.
        affectsRequired = try container.decodeIfPresent(Bool.self, forKey: .affectsRequired) ?? true
        affectsMaximum = try container.decodeIfPresent(Bool.self, forKey: .affectsMaximum) ?? true
        affectsCompensation = try container.decodeIfPresent(Bool.self, forKey: .affectsCompensation) ?? true
    }
}

enum FlexAttendance {
    private static func interval(_ block: FlexSchedule.Block) throws -> DateInterval {
        guard let from = block.value.startTimestamp?.timestamp,
              let to = block.value.endTimestampExclusive?.timestamp, to >= from else { throw FlexError.invalidData("근무·휴게·휴가 기록의 시작·종료 시각이 없거나 순서가 맞지 않습니다.") }
        return DateInterval(start: try FlexDates.timestamp(from), end: try FlexDates.timestamp(to))
    }
    private static func overlap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }
    private static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }
    private static func localTime(_ text: String, date: Date, zone: TimeZone) throws -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, (0...23).contains(parts[0]), (0...59).contains(parts[1]),
              (0...59).contains(parts[2]), let result = FlexDates.calendar(in: zone).date(
                bySettingHour: parts[0], minute: parts[1], second: parts[2], of: date) else { throw FlexError.invalidData("근무표의 시작·종료 시각 형식을 읽지 못했습니다.") }
        return result
    }

    static func snapshot(period: FlexPeriod, summary: FlexPeriodSummary, today: FlexDailySummary,
                         status: FlexClockStatus, schedules: [FlexSchedule], attributes: [FlexDayAttribute],
                         rule: FlexRule, customHoliday: CustomHolidayRule? = nil,
                         serverClockOffset: TimeInterval = 0) throws -> AttendanceSnapshot {
        guard let zone = TimeZone(identifier: period.zoneId), status.appliedZoneId == period.zoneId,
              summary.result.timezone == period.zoneId else { throw FlexError.invalidData("근무 기록과 월간 집계의 시간대가 맞지 않습니다.") }
        let calendar = FlexDates.calendar(in: zone)
        let now = try FlexDates.timestamp(status.requestedAt)
        let start = try FlexDates.day(period.from, in: zone), end = try FlexDates.day(period.to, in: zone)
        let result = summary.result
        guard end >= start, end.timeIntervalSince(start) <= 366 * 86400,
              result.period.from == period.applyTimeRangeFrom, result.period.to == period.applyTimeRangeTo else {
            throw FlexError.invalidData("근무 기록과 월간 집계의 정산 기간이 맞지 않습니다.")
        }
        guard (1...1440).contains(rule.baseAgreedDayWorkingMinutes) else {
            throw FlexError.invalidData("회사 근무 규칙의 하루 소정근로시간을 확인하지 못했습니다.")
        }
        guard [result.currentTargetWorkingMinutes, result.totalRecognizedWorkingMinutes, result.totalOverWorkingMinutes,
               result.requiredAgreedWorkingMinutes, today.totalActualWorkingMinutes, today.totalRecognizedWorkingMinutes]
                .allSatisfy({ (0...527040).contains($0) }),
              result.requiredMaxStatutoryWorkingMinutes.map({ (0...527040).contains($0) }) ?? true else {
            throw FlexError.invalidData("근무시간 집계 값이 허용 범위를 벗어났습니다.")
        }
        guard today.totalActualWorkingMinutes <= result.currentTargetWorkingMinutes,
              today.totalRecognizedWorkingMinutes <= result.totalRecognizedWorkingMinutes else {
            throw FlexError.invalidData("오늘 근무시간이 월간 집계보다 큽니다.")
        }
        guard Set(schedules.map(\.date)).count == schedules.count,
              Set(attributes.map(\.date)).count == attributes.count else {
            throw FlexError.invalidData("같은 날짜의 근무 정보가 중복되어 있습니다.")
        }
        let active = status.onGoingRecordPack.flatMap { $0.onGoing ? $0 : nil }
        let activeStart = try active.map { try FlexDates.timestamp($0.startRecord.targetTime) }
        let workDate = activeStart.map { FlexDates.key($0, in: zone) } ?? status.targetDate
        guard workDate >= period.from, workDate <= period.to else { throw FlexError.invalidData("현재 근무일이 정산 기간에 포함되지 않습니다.") }
        let days = Dictionary(uniqueKeysWithValues: schedules.map { ($0.date, $0) })
        let dates = Dictionary(uniqueKeysWithValues: attributes.map { ($0.date, $0) })
        guard days[workDate] != nil, dates[workDate] != nil else { throw FlexError.invalidData("현재 근무일의 일정 또는 근무 기준이 없습니다.") }
        var cursor = start
        while cursor <= end {
            let key = FlexDates.key(cursor, in: zone)
            guard days[key] != nil, dates[key] != nil else { throw FlexError.invalidData("정산 기간의 일부 날짜에 근무 정보가 없습니다.") }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        var rows: [DailyRecord] = [], holidays: [String: CompanyHoliday] = [:]
        var customHolidayMinutes = 0, customHolidayDates: [String] = []
        var excluded: [DateInterval] = []
        var remindersAvailable = true
        var liveWorkClock: LiveWorkClock?
        var todayRestMinutes: Int?
        var dailyTarget = rule.baseAgreedDayWorkingMinutes
        for attribute in attributes.sorted(by: { $0.date < $1.date }) {
            guard attribute.timezone == period.zoneId, let day = days[attribute.date],
                  (0...1440).contains(attribute.usualWorkingMinutes) else { throw FlexError.invalidData("날짜별 근무 일정·시간대·소정근로시간을 확인하지 못했습니다.") }
            let date = try FlexDates.day(attribute.date, in: zone)
            let blocks = Set(day.timeBlocks)
            guard blocks.allSatisfy({ ["WORK", "REST", "TIME_OFF", "ANNUAL_TIME_OFF"].contains($0.type) }) else { throw FlexError.invalidData("앱이 지원하지 않는 근무 일정 유형이 있습니다.") }
            let workBlocks = blocks.filter { $0.type == "WORK" && $0.value.eventStatus == "RECORD" }
            let work = try workBlocks.map(interval).sorted { $0.start < $1.start }
            guard zip(work, work.dropFirst()).allSatisfy({ $0.end <= $1.start }) else { throw FlexError.invalidData("확정된 근무 기록끼리 시간이 겹칩니다.") }
            let rests = union(try blocks.filter { $0.type == "REST" && $0.value.eventStatus == "RECORD" }.map(interval))
            let completed = Int(work.reduce(0.0) { total, part in
                total + part.duration - rests.reduce(0) { $0 + overlap($1, part) }
            } / 60)
            let leave = blocks.filter { $0.type == "TIME_OFF" || $0.type == "ANNUAL_TIME_OFF" }
            guard leave.allSatisfy({ $0.value.usedMinutes.map { (0...1440).contains($0) } ?? true }) else { throw FlexError.invalidData("휴가 사용시간이 허용 범위를 벗어났습니다.") }
            let usedLeave = leave.compactMap(\.value.usedMinutes).reduce(0, +)
            let leaveIntervals = try leave.filter { $0.value.startTimestamp != nil && $0.value.endTimestampExclusive != nil }.map(interval)
            let fullLeave = leave.contains { $0.value.allDay == true } || (attribute.usualWorkingMinutes > 0 && usedLeave >= attribute.usualWorkingMinutes)
            let isFlexWorkday = attribute.dateType == "IN_EMPLOY" && attribute.usualWorkingMinutes > 0 && attribute.dayOffs.isEmpty && day.dayOffs.isEmpty && !fullLeave
            let isCustomHoliday = isFlexWorkday && customHoliday?.contains(date, calendar: calendar) == true
            if isCustomHoliday && day.date >= period.from && day.date <= period.to {
                customHolidayMinutes += attribute.usualWorkingMinutes
                customHolidayDates.append(day.date)
            }
            let isWorkday = isFlexWorkday && !isCustomHoliday
            let plannedStart = try attribute.coreTime.map { try localTime($0.start, date: date, zone: zone) }
            let plannedEnd = try attribute.coreTime.map { range in
                let end = try localTime(range.endInclusive, date: date, zone: zone)
                return range.dayPassed ? calendar.date(byAdding: .day, value: 1, to: end)! : end
            } ?? calendar.date(byAdding: .day, value: 1, to: date)!
            var row = DailyRecord(date: day.date, start: work.first.map { FlexDates.iso($0.start, in: zone) },
                end: work.last.map { FlexDates.iso($0.end, in: zone) },
                scheduledStart: plannedStart.map { FlexDates.iso($0, in: zone) }, scheduledEnd: FlexDates.iso(plannedEnd, in: zone),
                workedMinutes: completed)
            row.scheduledWorkday = isWorkday
            for holiday in attribute.dayOffs where holiday.name != nil {
                if holidays[day.date] == nil || holiday.name!.hasSuffix("리프레시 데이") {
                    holidays[day.date] = CompanyHoliday(name: holiday.name!)
                }
            }
            if day.date == workDate {
                row = DailyRecord(date: row.date, start: row.start, end: row.end, scheduledStart: row.scheduledStart,
                    scheduledEnd: row.scheduledEnd, workedMinutes: today.totalRecognizedWorkingMinutes)
                row.scheduledWorkday = isWorkday
                excluded = union(leaveIntervals)
                remindersAvailable = plannedStart != nil && leave.allSatisfy {
                    // Flexible half-day records can use midnight offsets, not absence times.
                    $0.value.allDay == true || ($0.value.timeOffRegisterUnit != "HALF_DAY_AM" && $0.value.timeOffRegisterUnit != "HALF_DAY_PM" &&
                        $0.value.startTimestamp != nil && $0.value.endTimestampExclusive != nil)
                }
                let restRanges = try attribute.recommendedRestTimeRanges.map { range -> DateInterval in
                    let from = try localTime(range.start, date: date, zone: zone)
                    var to = try localTime(range.endInclusive, date: date, zone: zone)
                    if range.dayPassed { to = calendar.date(byAdding: .day, value: 1, to: to)! }
                    guard to >= from else { throw FlexError.invalidData("근무표의 휴게 종료 시각이 시작 시각보다 이릅니다.") }
                    return DateInterval(start: from, end: to)
                }
                todayRestMinutes = Int(union(restRanges).reduce(0.0) { $0 + $1.duration } / 60)
                dailyTarget = fullLeave ? 0 : max(0, attribute.usualWorkingMinutes - usedLeave)
                if let active, let activeStart {
                    guard active.startRecord.eventType == "START", active.startRecord.recordType == "RECORD",
                          active.stopRecord == nil, activeStart <= now,
                          active.switchRecords.allSatisfy({ $0.eventType == "SWITCH" && $0.targetTime >= active.startRecord.targetTime }) else {
                        throw FlexError.invalidData("진행 중인 출근·퇴근·근무 전환 기록이 맞지 않습니다.")
                    }
                    var liveRests: [DateInterval] = []
                    for rest in active.restRecords {
                        guard rest.restStartRecord.eventType == "REST_START",
                              rest.restStopRecord.map({ $0.eventType == "REST_STOP" }) ?? true else { throw FlexError.invalidData("진행 중인 휴게 기록의 시작·종료 유형이 맞지 않습니다.") }
                        let from = try FlexDates.timestamp(rest.restStartRecord.targetTime)
                        let to = try rest.restStopRecord.map { try FlexDates.timestamp($0.targetTime) } ?? .distantFuture
                        guard rest.restStopRecord == nil || to >= from else { throw FlexError.invalidData("휴게 기록의 종료 시각이 시작 시각보다 이릅니다.") }
                        let lower = max(from, activeStart), upper = to
                        if upper > lower { liveRests.append(DateInterval(start: lower, end: upper)) }
                    }
                    let clock = LiveWorkClock(start: activeStart, completedMinutes: today.totalRecognizedWorkingMinutes,
                                              rests: union(liveRests), countsTowardTarget: attribute.usualWorkingMinutes > 0 &&
                                                attribute.dayOffs.isEmpty && day.dayOffs.isEmpty)
                    // Recorded work already contributes to server totals; overlapping live time cannot be added again.
                    if work.allSatisfy({ $0.end <= activeStart }) { liveWorkClock = clock }
                    row = DailyRecord(date: row.date, start: FlexDates.iso(min(work.first?.start ?? activeStart, activeStart), in: zone),
                        scheduledStart: row.scheduledStart, scheduledEnd: row.scheduledEnd,
                        workedMinutes: today.totalRecognizedWorkingMinutes,
                        currentMinutes: liveWorkClock?.minutes(at: now) ?? today.totalRecognizedWorkingMinutes)
                    row.scheduledWorkday = isWorkday
                } else if status.onGoingRecordPack?.stopRecord != nil && work.isEmpty {
                    throw FlexError.invalidData("퇴근 기록에 대응하는 근무 내역이 없습니다.")
                }
                if today.totalRecognizedWorkingMinutes > 0 && row.start == nil { throw FlexError.invalidData("인정 근무시간은 있지만 시작 기록이 없습니다.") }
            }
            rows.append(row)
        }
        let requiredDeduction = customHoliday?.affectsRequired == true ? customHolidayMinutes : 0
        let maximumDeduction = customHoliday?.affectsMaximum == true ? customHolidayMinutes : 0
        let compensationDeduction = customHoliday?.affectsCompensation == true ? customHolidayMinutes : 0
        var month = MonthlyReport(workedMinutes: result.totalRecognizedWorkingMinutes, outsideMinutes: 0,
            requiredMinutes: max(0, result.requiredAgreedWorkingMinutes - requiredDeduction), vacationMinutes: 0, weekendMinutes: 0,
            dailyRequiredMinutes: rule.baseAgreedDayWorkingMinutes, startDate: period.from, endDate: period.to,
            maximumWorkMinutes: result.requiredMaxStatutoryWorkingMinutes.map { max(0, $0 - maximumDeduction) })
        month.targetCreditedMinutes = result.currentTargetWorkingMinutes
        var snapshot = AttendanceSnapshot(record: rows.first { $0.date == workDate }, month: month,
            remainingWorkDays: AttendanceSnapshot.remainingScheduledDays(in: rows, during: month, today: workDate, at: now),
            updatedAt: now, serverClockOffset: serverClockOffset)
        snapshot.service = .flex
        snapshot.timeZone = zone
        snapshot.todayCreditedMinutesInMonth = today.totalActualWorkingMinutes
        snapshot.dailyRestMinutes = todayRestMinutes
        snapshot.dailyTargetMinutes = dailyTarget
        snapshot.isEstimated = liveWorkClock != nil
        snapshot.liveWorkClock = liveWorkClock
        if active != nil && liveWorkClock == nil { snapshot.attendanceNote = "근무 중 · flex 집계 기준" }
        snapshot.advanceLiveTime(to: ServerClock(offset: serverClockOffset, updatedAt: now)
            .deviceTime(forServerTime: now))
        snapshot.remindersAvailable = remindersAvailable
        snapshot.reminderExcludedIntervals = excluded
        snapshot.averageClockInMinute = AttendanceSnapshot.averageClockInMinute(in: rows, before: workDate, timeZone: zone)
        snapshot.compensationEstimate = CompensationEstimate(month: month, days: rows, holidays: holidays,
            extraMinutes: requiredDeduction - compensationDeduction)
        snapshot.calendarRecords = rows
        snapshot.calendarHolidays = holidays
        snapshot.expectedClockOut = try status.onTimeInfo?.clockOutOnTimeInfo?.clockOnTime.map(FlexDates.timestamp)
        if customHoliday != nil {
            snapshot.customHolidayDeduction = CustomHolidayDeduction(dates: customHolidayDates, minutes: customHolidayMinutes,
                maximumMinutes: maximumDeduction, flexRequiredMinutes: result.requiredAgreedWorkingMinutes,
                flexMaximumMinutes: result.requiredMaxStatutoryWorkingMinutes)
        }
        return snapshot
    }
}
