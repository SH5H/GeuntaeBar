import Foundation
import Security

enum AttendanceService: String, CaseIterable {
    case wantedSpace, flex
    var name: String { self == .flex ? "flex" : "원티드스페이스" }
    var webURL: URL {
        URL(string: self == .flex ? "https://flex.team/time-tracking/my-work-record" : "https://dashboard.handyspace.ai/work/my-work")!
    }
}

struct SavedCookie: Codable, Hashable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let secure: Bool
    var httpOnly: Bool? = nil

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
    }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: secure ? "TRUE" : "FALSE"
        ]
        if let expires { properties[.expires] = expires }
        if httpOnly == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    var belongsToWantedSpace: Bool {
        belongsTo(.wantedSpace)
    }

    func belongsTo(_ service: AttendanceService) -> Bool {
        let host = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let domain = service == .flex ? "flex.team" : "handyspace.ai"
        return host == domain || host.hasSuffix("." + domain)
    }

    var isCurrent: Bool { expires.map { $0 > Date() } ?? true }
}

final class KeychainSession {
    struct Item {
        let service: String
        let account: String
    }

    private let service: String
    private let legacyService: String?
    private let attendanceService: AttendanceService
    private let legacyItemsToPurge: [Item]
    private let deleteItem: (Item) throws -> Void
    private var account: String { attendanceService == .flex ? "flex-cookies" : "wantedspace-cookies" }
    private var lastSavedCookies: Set<SavedCookie>?

    init(service: String = "ai.wantedspace.WorkBar.v3", legacyService: String? = nil,
         attendanceService: AttendanceService = .wantedSpace, legacyItemsToPurge: [Item] = [],
         deleteItem: ((Item) throws -> Void)? = nil) {
        self.service = service
        self.legacyService = legacyService
        self.attendanceService = attendanceService
        self.legacyItemsToPurge = legacyItemsToPurge
        self.deleteItem = deleteItem ?? { item in
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service, kSecAttrAccount as String: item.account] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
        }
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> [SavedCookie] {
        var data = try storedData(for: service)
        if data == nil, let legacyService,
           let oldData = try storedData(for: legacyService) {
            var attributes = query
            attributes[kSecValueData as String] = oldData
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status) }
            data = oldData
            var oldQuery = query
            oldQuery[kSecAttrService as String] = legacyService
            _ = SecItemDelete(oldQuery as CFDictionary)
        }
        guard let data else { lastSavedCookies = nil; return [] }
        let cookies = try JSONDecoder().decode([SavedCookie].self, from: data)
            .filter { $0.belongsTo(attendanceService) && $0.isCurrent }
        lastSavedCookies = Set(cookies)
        return cookies
    }

    private func storedData(for service: String) throws -> Data? {
        var request = query
        request[kSecAttrService as String] = service
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status)
        }
        return data
    }

    @discardableResult
    func save(_ cookies: [HTTPCookie]) throws -> Bool {
        let stored = cookies.map(SavedCookie.init)
            .filter { $0.belongsTo(attendanceService) && $0.isCurrent }
        if Set(stored) == lastSavedCookies { return false }
        let data = try JSONEncoder().encode(stored)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError(update) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
        lastSavedCookies = Set(stored)
        return true
    }

    func purgeLegacyItems() throws {
        for item in legacyItemsToPurge { try deleteItem(item) }
    }

    func delete() throws {
        lastSavedCookies = nil
        for service in [service, legacyService].compactMap({ $0 }) {
            var request = query
            request[kSecAttrService as String] = service
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status)
            }
        }
        try purgeLegacyItems()
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? { "Keychain 오류 (\(status))" }
}

struct DailyRecord: Decodable {
    let date: String
    let start: String?
    let end: String?
    let scheduledStart: String?
    let scheduledEnd: String?
    let workedMinutes: Int?
    var currentMinutes: Int?
    let outsideMinutes: Int?
    let holidayStatus: String?
    var scheduledWorkday: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case date = "wk_date"
        case start = "wk_start_time"
        case end = "wk_end_time"
        case scheduledStart = "wk_start_time_sch"
        case scheduledEnd = "wk_end_time_sch"
        case workedMinutes = "wk_time_min"
        case currentMinutes = "wk_time_min_now"
        case outsideMinutes = "evt_out_min"
        case holidayStatus = "wk_holiday"
    }

    init(date: String, start: String? = nil, end: String? = nil,
         scheduledStart: String? = nil, scheduledEnd: String? = nil,
         workedMinutes: Int? = nil, currentMinutes: Int? = nil,
         outsideMinutes: Int? = nil, holidayStatus: String? = nil) {
        self.date = date
        self.start = start
        self.end = end
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.workedMinutes = workedMinutes
        self.currentMinutes = currentMinutes
        self.outsideMinutes = outsideMinutes
        self.holidayStatus = holidayStatus
    }

    var isWorking: Bool { start?.isEmpty == false && end?.isEmpty != false }
    var isScheduledWorkday: Bool { scheduledWorkday ?? (holidayStatus?.contains("_WORKING_ON_") == true) }
    var isScheduledDayOff: Bool { scheduledWorkday.map { !$0 } ?? (holidayStatus?.contains("_WORKING_OFF_") == true) }
    var scheduledStartDate: Date? {
        guard let scheduledStart else { return nil }
        return ISO8601DateFormatter().date(from: scheduledStart)
    }
    var scheduledEndDate: Date? {
        guard let scheduledEnd else { return nil }
        return ISO8601DateFormatter().date(from: scheduledEnd)
    }
    var totalMinutes: Int? {
        let minutes = isWorking ? currentMinutes : workedMinutes
        guard let minutes else { return nil }
        return max(0, minutes + (outsideMinutes ?? 0))
    }
}

struct MonthlyReport: Decodable {
    var workedMinutes: Int
    let outsideMinutes: Int
    var requiredMinutes: Int
    let vacationMinutes: Int
    let weekendMinutes: Int
    let dailyRequiredMinutes: Int
    let startDate: String
    let endDate: String
    var maximumWorkMinutes: Int?
    var targetCreditedMinutes: Int? = nil

    enum CodingKeys: String, CodingKey {
        case workedMinutes = "wk_time_week"
        case outsideMinutes = "wk_out_min"
        case requiredMinutes = "wk_time_recom"
        case vacationMinutes = "wk_vac_min"
        case weekendMinutes = "wk_weekend_min"
        case dailyRequiredMinutes = "cont_work_day"
        case startDate = "start_date"
        case endDate = "end_date"
        case maximumWorkMinutes = "wk_time_max"
    }

    var actualMinutes: Int { workedMinutes + outsideMinutes }
    var creditedMinutes: Int { targetCreditedMinutes ?? actualMinutes }
    var targetMinutes: Int { requiredMinutes - vacationMinutes + weekendMinutes }
    var balance: Int {
        creditedMinutes - targetMinutes
    }
    var remainingMinutes: Int { max(0, -balance) }
}

struct WorkMeter {
    let actualMinutes: Int
    let targetMinutes: Int

    var fillFraction: Double {
        guard targetMinutes > 0 else { return 0 }
        return min(1, Double(max(0, actualMinutes)) / Double(targetMinutes))
    }
    var percent: Int {
        guard targetMinutes > 0 else { return 0 }
        return Int((Double(actualMinutes) / Double(targetMinutes) * 100).rounded())
    }
}

enum ClockInReminderMode: String {
    case scheduled
    case average
}

struct LiveWorkClock {
    let start: Date
    let completedMinutes: Int
    let rests: [DateInterval]
    let countsTowardTarget: Bool

    func minutes(at date: Date) -> Int {
        let end = max(start, date)
        let restSeconds = rests.reduce(0.0) {
            $0 + max(0, min($1.end, end).timeIntervalSince(max($1.start, start)))
        }
        return completedMinutes + Int(max(0, end.timeIntervalSince(start) - restSeconds) / 60)
    }

    func isResting(at date: Date) -> Bool {
        rests.contains { date >= $0.start && date < $0.end }
    }
}

struct LeaveOptions: Codable, Equatable {
    var recognizesScheduledWork = false
    var recognizesOvertime = false

    var title: String { "직접 지정 휴가" }
}

struct ClockInReminderPlan {
    let day: String
    let identifier: String
    let title: String
    let body: String
}

enum ClockInReminderPlanner {
    static func plan(snapshot: AttendanceSnapshot, now: Date, mode: ClockInReminderMode, delayMinutes: Int,
                     lastRemindedDay: String?, account: String) -> ClockInReminderPlan? {
        guard let day = snapshot.record?.date, day != lastRemindedDay,
              snapshot.shouldRemindToClockIn(at: now, mode: mode, delayMinutes: delayMinutes) else { return nil }
        return ClockInReminderPlan(day: day, identifier: "clock-in-\(account)-\(day)",
            title: "오늘 출근하셨나요?",
            body: "출근 기록이 아직 없습니다. \(snapshot.service.name)에서 확인해주세요.")
    }
}

struct ServerClock {
    let offset: TimeInterval
    let updatedAt: Date

    init(serverTime: Date, deviceTime: Date) {
        offset = serverTime.timeIntervalSince(deviceTime)
        updatedAt = serverTime
    }
    init(offset: TimeInterval, updatedAt: Date) {
        self.offset = offset
        self.updatedAt = updatedAt
    }
    func serverTime(for deviceTime: Date) -> Date {
        max(updatedAt, deviceTime.addingTimeInterval(offset))
    }
    func deviceTime(forServerTime serverTime: Date) -> Date {
        serverTime.addingTimeInterval(-offset)
    }

    func isFresh(at deviceTime: Date) -> Bool {
        serverTime(for: deviceTime).timeIntervalSince(updatedAt) <= 300
    }

    func advance(_ snapshot: inout AttendanceSnapshot, deviceNow: Date) {
        guard let liveWorkClock = snapshot.liveWorkClock, snapshot.attendanceKnown,
              snapshot.record?.isWorking == true else { return }
        let serverNow = serverTime(for: deviceNow)
        let minutes = max(snapshot.record?.currentMinutes ?? 0, liveWorkClock.minutes(at: serverNow))
        snapshot.record?.currentMinutes = minutes
        snapshot.attendanceNote = liveWorkClock.isResting(at: serverNow) ? "휴게 중" : "근무 중"
    }
}

struct LeaveDeduction {
    let dates: [String]
    let minutes: Int
    let maximumMinutes: Int
}

struct AttendanceSnapshot {
    var record: DailyRecord?
    var month: MonthlyReport
    var remainingWorkDays: Int
    let updatedAt: Date
    var calendarRecords: [DailyRecord] = []
    var calendarHolidays: [String: CompanyHoliday] = [:]
    var compensationEstimate: CompensationEstimate? = nil
    var averageClockInMinute: Int? = nil
    var dailyRestMinutes: Int? = nil
    var service: AttendanceService = .wantedSpace
    var accountIdentifier = ""
    var timeZone: TimeZone = .current
    var isEstimated = false
    var attendanceKnown = true
    var attendanceNote: String? = nil
    var dailyTargetMinutes: Int? = nil
    var remindersAvailable = true
    var reminderExcludedIntervals: [DateInterval] = []
    var todayCreditedMinutesInMonth: Int? = nil
    var expectedClockOut: Date? = nil
    var liveWorkClock: LiveWorkClock? = nil
    var serverClockOffset: TimeInterval = 0
    var leaveByDate: [String: LeaveOptions] = [:]
    var calendarRequiredMinutes: [String: Int] = [:]
    var leaveDeduction: LeaveDeduction? = nil

    func applyingLeave(_ leaves: [String: LeaveOptions]) -> AttendanceSnapshot {
        var snapshot = self
        snapshot.leaveByDate = leaves
        let today = record?.date ?? calendarDate
        var deductions = 0
        var overtimeDeductions = 0
        var excludedDays = 0
        var deductedDates: [String] = []
        for (date, options) in leaves where date >= month.startDate && date <= month.endDate {
            if let index = calendarRecords.firstIndex(where: { $0.date == date }) {
                let original = record?.date == date ? record! : calendarRecords[index]
                excludedDays += Self.remainingScheduledDays(in: [original], during: month,
                                                            today: today, at: updatedAt)
                snapshot.calendarRecords[index].scheduledWorkday = false
                if snapshot.record?.date == date { snapshot.record?.scheduledWorkday = false }
            }
            guard let required = calendarRequiredMinutes[date], required > 0,
                  calendarHolidays[date] == nil else { continue }
            if options.recognizesScheduledWork {
                deductions += required
                deductedDates.append(date)
            }
            if options.recognizesOvertime { overtimeDeductions += required }
        }
        snapshot.month.requiredMinutes = max(0, month.requiredMinutes - deductions)
        if let maximum = month.maximumWorkMinutes {
            snapshot.month.maximumWorkMinutes = max(0, maximum - deductions)
        }
        snapshot.remainingWorkDays = max(0, remainingWorkDays - excludedDays)
        snapshot.compensationEstimate?.thresholdMinutes =
            max(0, (compensationEstimate?.thresholdMinutes ?? 0) - overtimeDeductions)
        snapshot.leaveDeduction = deductions > 0
            ? LeaveDeduction(dates: deductedDates.sorted(),
                             minutes: month.targetMinutes - snapshot.month.targetMinutes,
                             maximumMinutes: (month.maximumWorkMinutes ?? 0) - (snapshot.month.maximumWorkMinutes ?? 0))
            : nil
        if let date = record?.date, date >= month.startDate, date <= month.endDate, leaves[date] != nil {
            snapshot.dailyTargetMinutes = 0
            snapshot.remindersAvailable = false
        }
        return snapshot
    }

    mutating func advanceLiveTime(to date: Date) {
        ServerClock(offset: serverClockOffset, updatedAt: updatedAt).advance(&self, deviceNow: date)
    }

    var ongoingMinutes: Int {
        guard let liveWorkClock, record?.isWorking == true else { return 0 }
        return max(0, todayMinutes - liveWorkClock.completedMinutes)
    }

    var displayMonth: MonthlyReport {
        guard let liveWorkClock else { return month }
        var result = month
        result.workedMinutes += ongoingMinutes
        result.targetCreditedMinutes = month.creditedMinutes + (liveWorkClock.countsTowardTarget ? ongoingMinutes : 0)
        return result
    }

    var displayCompensationEstimate: CompensationEstimate? {
        guard var result = compensationEstimate else { return nil }
        result.countedMinutes = displayMonth.creditedMinutes
        return result
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private var calendarDate: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: updatedAt)
    }
    var dayTitle: String {
        guard let record, record.date != calendarDate else { return "오늘" }
        return record.date
    }
    var monthTitle: String {
        month.startDate.prefix(7) == calendarDate.prefix(7) ? "이번 달" : String(month.startDate.prefix(7))
    }

    var todayMinutes: Int { record?.totalMinutes ?? 0 }
    var todayMeter: WorkMeter {
        WorkMeter(actualMinutes: todayMinutes, targetMinutes: 480)
    }
    /// Remaining workdays this month; today counts while it is a scheduled workday not yet finished.
    private var remainingDaysIncludingToday: Int {
        let countedToday = record.map {
            Self.remainingScheduledDays(in: [$0], during: month, today: $0.date, at: updatedAt)
        } ?? 0
        return remainingWorkDays + (record?.isScheduledWorkday == true ? 1 - countedToday : 0)
    }
    var minimumTodayMeter: WorkMeter? {
        guard attendanceKnown else { return nil }
        if let date = record?.date, leaveByDate[date] != nil,
           date >= month.startDate, date <= month.endDate { return nil }
        let days = remainingDaysIncludingToday
        guard days > 0 else { return nil }
        let remainingBeforeToday = max(0, month.targetMinutes - month.creditedMinutes + (todayCreditedMinutesInMonth ?? todayMinutes))
        let target = Int(ceil(Double(remainingBeforeToday) / Double(days)))
        return WorkMeter(actualMinutes: todayMinutes, targetMinutes: target)
    }
    var remainingWorkDaysAfterToday: Int {
        max(0, remainingDaysIncludingToday - (record?.isScheduledWorkday == true ? 1 : 0))
    }
    var remainingRequiredWorkDays: Int {
        guard let record, record.isScheduledWorkday, record.end?.isEmpty != false,
              record.date >= month.startDate, record.date <= month.endDate else {
            return remainingWorkDaysAfterToday
        }
        return remainingWorkDaysAfterToday + 1
    }
    var dailyRequiredHours: Double? {
        let days = remainingRequiredWorkDays
        guard attendanceKnown, days > 0 else { return nil }
        return Double(displayMonth.remainingMinutes) / Double(days) / 60
    }
    var minimumTodayOvertimeMinutes: Int {
        guard let meter = minimumTodayMeter else { return 0 }
        return max(0, meter.actualMinutes - meter.targetMinutes)
    }
    var monthMeter: WorkMeter {
        WorkMeter(actualMinutes: displayMonth.creditedMinutes, targetMinutes: month.targetMinutes)
    }
    var overtimeMeter: WorkMeter? {
        guard let maximum = month.maximumWorkMinutes,
              maximum > month.targetMinutes else { return nil }
        return WorkMeter(actualMinutes: max(0, displayMonth.actualMinutes - min(displayMonth.creditedMinutes, month.targetMinutes)),
                         targetMinutes: maximum - month.targetMinutes)
    }
    var expectedMinutesByNow: Int {
        let expected = month.targetMinutes - remainingWorkDaysAfterToday * month.dailyRequiredMinutes
        return min(max(0, expected), max(0, month.targetMinutes))
    }
    var paceFraction: Double {
        guard month.targetMinutes > 0 else { return 0 }
        return Double(expectedMinutesByNow) / Double(month.targetMinutes)
    }
    var paceDifferenceMinutes: Int { displayMonth.creditedMinutes - expectedMinutesByNow }
    func clockInReminderDate(mode: ClockInReminderMode, delayMinutes: Int) -> Date? {
        guard record?.start?.isEmpty != false, record?.end?.isEmpty != false else { return nil }
        return scheduledClockInReminderDate(mode: mode, delayMinutes: delayMinutes)
    }
    func clockInReminderTime(mode: ClockInReminderMode, delayMinutes: Int) -> String {
        guard attendanceKnown else { return "--:--" }
        guard let date = scheduledClockInReminderDate(mode: mode, delayMinutes: delayMinutes) else {
            return "알림 없음"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    private func scheduledClockInReminderDate(mode: ClockInReminderMode, delayMinutes: Int) -> Date? {
        guard remindersAvailable, let record, record.isScheduledWorkday,
              let start = record.scheduledStartDate,
              let end = record.scheduledEndDate else { return nil }
        let averageStart = averageClockInMinute.flatMap {
            calendar.date(byAdding: .minute, value: $0, to: calendar.startOfDay(for: start))
        }
        let baseline = mode == .average ? max(start, averageStart ?? start) : start
        var reminderDate = baseline.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
        for interval in reminderExcludedIntervals.sorted(by: { $0.start < $1.start }) {
            if reminderDate >= interval.start && reminderDate < interval.end { reminderDate = interval.end }
        }
        return reminderDate < end ? reminderDate : nil
    }
    func shouldRemindToClockIn(at now: Date, mode: ClockInReminderMode,
                             delayMinutes: Int) -> Bool {
        guard let reminderDate = clockInReminderDate(mode: mode, delayMinutes: delayMinutes),
              let end = record?.scheduledEndDate else { return false }
        return now >= reminderDate && now < end &&
            !reminderExcludedIntervals.contains { now >= $0.start && now < $0.end }
    }
    var paceDescription: String {
        let baseline = "빨간 선: \(dayTitle)까지 기준 \(Self.duration(expectedMinutesByNow))"
        guard displayMonth.balance < 0 else { return baseline }
        return baseline + " · " + (paceDifferenceMinutes >= 0
            ? "\(Self.duration(paceDifferenceMinutes)) 앞섬"
            : "\(Self.duration(-paceDifferenceMinutes)) 부족")
    }

    static func remainingScheduledDays(in records: [DailyRecord],
                                       during month: MonthlyReport,
                                       today: String,
                                       at now: Date) -> Int {
        records.filter { record in
            guard record.isScheduledWorkday,
                  record.date >= month.startDate,
                  record.date <= month.endDate else { return false }
            if record.date > today { return true }
            return record.date == today && record.end?.isEmpty != false &&
                record.scheduledEndDate.map { now < $0 } == true
        }.count
    }

    static func averageClockInMinute(in records: [DailyRecord], before today: String,
                                     timeZone: TimeZone = .current) -> Int? {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let times = records.filter { $0.date < today && $0.isScheduledWorkday }
            .sorted { $0.date > $1.date }
            .compactMap { $0.start.flatMap(formatter.date(from:)) }
            .prefix(20)
            .map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }
        guard !times.isEmpty else { return nil }
        return Int((Double(times.reduce(0, +)) / Double(times.count)).rounded())
    }

    var menuTitle: String {
        guard attendanceKnown else { return "근태 --" }
        guard let record else { return "근태 --" }
        if record.start?.isEmpty != false { return "출근 전" }
        let state = record.end?.isEmpty == false ? "퇴근" : "근무"
        if let minutes = record.totalMinutes {
            let overtime = minimumTodayOvertimeMinutes
            let extra = overtime > 0 ? String(format: " · +%d:%02d", overtime / 60, overtime % 60) : ""
            return "\(state) \(Self.duration(minutes))\(extra)"
        }
        return "\(state) --"
    }

    var attendanceDescription: String {
        guard attendanceKnown else { return "오늘 근태 확인 불가" }
        guard let record else { return "오늘 기록 없음" }
        let clockIn = "출근 \(Self.clock(record.start))"
        if record.end?.isEmpty == false {
            return clockIn + " · 퇴근 \(Self.clock(record.end))"
        }
        if !record.isWorking {
            return clockIn + (record.scheduledEnd != nil
                ? " · 근무표 종료 \(Self.clock(record.scheduledEnd))" : "")
        }
        if let expectedClockOut {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            return clockIn + " · 예상 퇴근 \(formatter.string(from: expectedClockOut))"
        }
        guard let dailyRestMinutes, dailyRestMinutes >= 0,
              let start = record.start.flatMap({ ISO8601DateFormatter().date(from: $0) }) else {
            return clockIn
        }
        let expectedEnd = start.addingTimeInterval(Double((dailyTargetMinutes ?? month.dailyRequiredMinutes) + dailyRestMinutes) * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return clockIn + " · 예상 퇴근 \(formatter.string(from: expectedEnd))" + (service == .flex ? " (회사 근무 기준)" : "")
    }

    static func duration(_ minutes: Int) -> String {
        "\(minutes / 60)시간 \(minutes % 60)분"
    }

    static func clock(_ value: String?) -> String {
        guard let value else { return "--:--" }
        let time = value.split(whereSeparator: { $0 == "T" || $0 == " " }).last.map(String.init) ?? value
        let pieces = time.split(separator: ":")
        guard pieces.count >= 2 else { return "--:--" }
        return "\(pieces[0]):\(pieces[1])"
    }
}

enum AttendanceError: LocalizedError {
    case signInRequired
    case unexpectedResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "로그인이 필요합니다"
        case .unexpectedResponse: "근태 데이터를 읽을 수 없습니다"
        case .httpStatus(let status, let path): "근태 API 응답 \(status) (\(path))"
        }
    }
}

final class AttendanceClient {
    private let base = URL(string: "https://api.handyspace.ai")!
    private let session: URLSession
    private let cookies: HTTPCookieStorage

    init(cookies: HTTPCookieStorage = .shared, configuration: URLSessionConfiguration = .default) {
        self.cookies = cookies
        configuration.httpCookieStorage = cookies
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    func restore(_ saved: [SavedCookie]) {
        for item in saved where item.belongsToWantedSpace && item.isCurrent {
            if let cookie = item.cookie { cookies.setCookie(cookie) }
        }
    }

    func currentCookies() -> [HTTPCookie] {
        cookies.cookies ?? []
    }

    func clearCookies() {
        for cookie in currentCookies() where SavedCookie(cookie).belongsToWantedSpace {
            cookies.deleteCookie(cookie)
        }
    }

    func cancelRequests() async {
        for task in await session.allTasks { task.cancel() }
    }

    func snapshot(for day: Date = Date(), includePreviousMonth: Bool = false) async throws -> AttendanceSnapshot {
        let profile = try await get("/user/users/get_profile/")
        guard let object = try JSONSerialization.jsonObject(with: profile) as? [String: Any],
              let userProfile = object["user_profile"] as? [String: Any],
              let rawID = userProfile["user_id"] else {
            throw AttendanceError.unexpectedResponse
        }
        let userID = String(describing: rawID)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: day)
        var components = URLComponents(url: base.appendingPathComponent("work/work_time/"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "type", value: "month"),
                                 URLQueryItem(name: "org_range", value: "team"),
                                 URLQueryItem(name: "date", value: today),
                                 URLQueryItem(name: "user_id", value: userID)]
        let data = try await get(components.url!)
        let currentRows = try JSONDecoder().decode([DailyRecord].self, from: data)
        let needsPreviousMonth = !currentRows.contains {
            $0.date <= today && $0.start?.isEmpty == false
        }
        var previousRows: [DailyRecord] = []
        if includePreviousMonth || needsPreviousMonth,
           let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: day) {
            components.queryItems = components.queryItems?.map {
                $0.name == "date" ? URLQueryItem(name: "date", value: formatter.string(from: previousMonth)) : $0
            }
            do {
                let data = try await get(components.url!)
                previousRows = try JSONDecoder().decode([DailyRecord].self, from: data)
            } catch {
                if needsPreviousMonth { throw error }
            }
        }
        let allRows = currentRows + previousRows
        let latestAttendance = allRows.filter {
            $0.date <= today && $0.start?.isEmpty == false
        }.max { $0.date < $1.date }
        let record = latestAttendance?.isWorking == true
            ? latestAttendance : currentRows.first { $0.date.hasPrefix(today) }
        let workDate = record?.date ?? today
        let rows = workDate.prefix(7) == today.prefix(7) ? currentRows : previousRows
        var reportURL = URLComponents(url: base.appendingPathComponent("work/work_time/work_report/"),
                                      resolvingAgainstBaseURL: false)!
        reportURL.queryItems = [URLQueryItem(name: "date", value: workDate)]
        let reportData = try await get(reportURL.url!)
        let report = try JSONDecoder().decode(MonthlyReport.self, from: reportData)
        let remainingDays = AttendanceSnapshot.remainingScheduledDays(in: rows, during: report,
                                                                      today: workDate, at: day)
        var snapshot = AttendanceSnapshot(record: record, month: report,
                                          remainingWorkDays: remainingDays, updatedAt: day)
        snapshot.accountIdentifier = userID
        snapshot.dailyRestMinutes = userProfile["wk_except_legal"] as? Int
        snapshot.averageClockInMinute = AttendanceSnapshot.averageClockInMinute(in: allRows, before: workDate)
        var holidays: [String: CompanyHoliday] = [:]
        if let holidayData = try? await get("/work/sch_event/company_holidays/"),
           let decoded = try? JSONDecoder().decode([String: CompanyHoliday].self, from: holidayData) {
            holidays = decoded
            snapshot.compensationEstimate = CompensationEstimate(month: report, days: rows,
                                                                  holidays: decoded)
        }
        snapshot.calendarRecords = allRows
        snapshot.calendarHolidays = holidays
        snapshot.calendarRequiredMinutes = allRows.reduce(into: [:]) { required, row in
            guard row.date >= report.startDate && row.date <= report.endDate else { return }
            required[row.date] = row.isScheduledWorkday ? report.dailyRequiredMinutes : 0
        }
        return snapshot
    }

    private func get(_ path: String) async throws -> Data {
        try await get(base.appendingPathComponent(path))
    }

    private func get(_ url: URL) async throws -> Data {
        let request = authorizedRequest(url)
        var (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttendanceError.unexpectedResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 498 {
            try await refreshToken()
            (data, response) = try await session.data(for: authorizedRequest(url))
        }
        guard let response = response as? HTTPURLResponse else {
            throw AttendanceError.unexpectedResponse
        }
        if response.statusCode == 401 || response.statusCode == 498 {
            throw AttendanceError.signInRequired
        }
        guard response.statusCode == 200 else {
            throw AttendanceError.httpStatus(response.statusCode, url.path)
        }
        return data
    }

    private func refreshToken() async throws {
        var request = authorizedRequest(base.appendingPathComponent("v1/auth/refresh-token/"))
        request.httpMethod = "POST"
        if let csrf = cookies.cookies(for: base)?.first(where: { $0.name == "csrftoken" }) {
            request.setValue(csrf.value, forHTTPHeaderField: "X-CSRFToken")
        }
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AttendanceError.signInRequired
        }
    }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("ko", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("https://dashboard.handyspace.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://dashboard.handyspace.ai/", forHTTPHeaderField: "Referer")
        if let validCookies = cookies.cookies(for: url), !validCookies.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: validCookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }
}
