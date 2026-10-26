import Foundation

final class AttendanceStubProtocol: URLProtocol {
    static var responses: [String: String] = [:]
    static var statuses: [String: Int] = [:]
    static var requests: [String] = []
    static var onRequest: ((URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.handyspace.ai"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let date = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "date" }?.value
        let path = "/" + url.path.split(separator: "/").joined(separator: "/") + "/"
        let key = path + (date.map { "?date=\($0)" } ?? "")
        Self.requests.append(key)
        Self.onRequest?(request)
        guard let body = Self.responses[key] else { preconditionFailure("Unexpected request: \(key)") }
        let response = HTTPURLResponse(url: url, statusCode: Self.statuses[key] ?? 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct CoreTests {
    static func main() async throws {
        monthlyBaselineChecks()
        try flexAccountingChecks()
        leaveChecks()
        try await renewalChecks()
        try await overnightChecks()
        let json = Data(#"{"wk_date":"2026-09-29","wk_start_time":"2026-09-29T09:00:00+09:00","wk_end_time":null,"wk_end_time_sch":"2026-09-29T18:00:00+09:00","wk_time_min":120,"wk_time_min_now":135,"evt_out_min":15}"#.utf8)
        let record = try JSONDecoder().decode(DailyRecord.self, from: json)
        let month = try JSONDecoder().decode(MonthlyReport.self, from: Data(#"{"wk_time_week":8244,"wk_out_min":420,"wk_time_recom":8160,"wk_vac_min":240,"wk_weekend_min":0,"cont_work_day":480,"residual_days":1,"start_date":"2026-09-01","end_date":"2026-09-30","wk_time_max":13371}"#.utf8))
        precondition(record.isWorking)
        precondition(record.totalMinutes == 150)
        precondition(month.balance == 744)
        precondition(month.actualMinutes == 8664)
        precondition(month.targetMinutes == 7920)
        let today = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-29","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE","wk_end_time_sch":"2026-09-29T18:00:00+09:00"}"#.utf8))
        let tomorrowOff = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-30","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE","wk_start_time_sch":"2026-09-30T09:00:00+09:00","wk_end_time_sch":"2026-09-30T18:00:00+09:00"}"#.utf8))
        let tomorrowOn = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-30","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE","wk_end_time_sch":"2026-09-30T18:00:00+09:00"}"#.utf8))
        let finishedToday = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-29","wk_holiday":"WEEKDAY_WORKING_ON_NONE_INOUT","wk_end_time":"2026-09-29T11:00:00+09:00","wk_end_time_sch":"2026-09-29T18:00:00+09:00"}"#.utf8))
        let morning = ISO8601DateFormatter().date(from: "2026-09-29T10:00:00+09:00")!
        let evening = ISO8601DateFormatter().date(from: "2026-09-29T19:00:00+09:00")!
        let beforeReminder = ISO8601DateFormatter().date(from: "2026-09-29T08:59:00+09:00")!
        let atStart = ISO8601DateFormatter().date(from: "2026-09-29T09:00:00+09:00")!
        let afterDelay = ISO8601DateFormatter().date(from: "2026-09-29T09:15:00+09:00")!
        let beforeAverage = ISO8601DateFormatter().date(from: "2026-09-29T09:59:00+09:00")!
        let atAverage = ISO8601DateFormatter().date(from: "2026-09-29T10:00:00+09:00")!
        let missedClockIn = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-29","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE","wk_start_time_sch":"2026-09-29T09:00:00+09:00","wk_end_time_sch":"2026-09-29T18:00:00+09:00"}"#.utf8))
        let offDay = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-29","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE","wk_start_time_sch":"2026-09-29T09:00:00+09:00","wk_end_time_sch":"2026-09-29T18:00:00+09:00"}"#.utf8))
        var reminderSnapshot = AttendanceSnapshot(record: missedClockIn, month: month,
                                                  remainingWorkDays: 0, updatedAt: Date())
        reminderSnapshot.timeZone = TimeZone(identifier: "Asia/Seoul")!
        precondition(reminderSnapshot.clockInReminderDate(mode: .scheduled, delayMinutes: 0) == atStart)
        precondition(reminderSnapshot.clockInReminderDate(mode: .scheduled, delayMinutes: 15) == afterDelay)
        precondition(reminderSnapshot.clockInReminderTime(mode: .scheduled, delayMinutes: 0) == "09:00")
        precondition(reminderSnapshot.clockInReminderTime(mode: .scheduled, delayMinutes: 15) == "09:15")
        precondition(!reminderSnapshot.shouldRemindToClockIn(at: beforeReminder, mode: .scheduled, delayMinutes: 0))
        precondition(reminderSnapshot.shouldRemindToClockIn(at: atStart, mode: .scheduled, delayMinutes: 0))
        precondition(!reminderSnapshot.shouldRemindToClockIn(at: atStart, mode: .scheduled, delayMinutes: 15))
        precondition(reminderSnapshot.shouldRemindToClockIn(at: afterDelay, mode: .scheduled, delayMinutes: 15))
        precondition(!reminderSnapshot.shouldRemindToClockIn(at: evening, mode: .scheduled, delayMinutes: 0))
        precondition(reminderSnapshot.shouldRemindToClockIn(at: atStart, mode: .average, delayMinutes: 0))
        let reminderPlan = ClockInReminderPlanner.plan(snapshot: reminderSnapshot, now: afterDelay, mode: .scheduled,
            delayMinutes: 15, lastRemindedDay: nil, account: "flex-A001")!
        precondition(reminderPlan.day == missedClockIn.date)
        precondition(reminderPlan.identifier == "clock-in-flex-A001-\(missedClockIn.date)")
        precondition(reminderPlan.title == "오늘 출근하셨나요?")
        precondition(ClockInReminderPlanner.plan(snapshot: reminderSnapshot, now: afterDelay, mode: .scheduled,
            delayMinutes: 15, lastRemindedDay: missedClockIn.date, account: "flex-A001") == nil)
        let early = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-27","wk_holiday":"WEEKDAY_WORKING_ON_NONE_INOUT","wk_start_time":"2026-09-27T09:00:00+09:00"}"#.utf8))
        let late = try JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-09-28","wk_holiday":"WEEKDAY_WORKING_ON_NONE_INOUT","wk_start_time":"2026-09-28T11:00:00+09:00"}"#.utf8))
        precondition(AttendanceSnapshot.averageClockInMinute(in: [early, late, missedClockIn], before: "2026-09-29") == 600)
        reminderSnapshot.averageClockInMinute = 600
        precondition(reminderSnapshot.clockInReminderTime(mode: .average, delayMinutes: 15) == "10:15")
        var utcReminder = reminderSnapshot
        utcReminder.timeZone = TimeZone(secondsFromGMT: 0)!
        precondition(utcReminder.clockInReminderTime(mode: .scheduled, delayMinutes: 15) == "00:15")
        var vacationReminder = reminderSnapshot
        vacationReminder.reminderExcludedIntervals = [DateInterval(start: atStart, end: atAverage)]
        precondition(vacationReminder.clockInReminderTime(mode: .scheduled, delayMinutes: 15) == "10:00")
        let checkedIn = DailyRecord(date: missedClockIn.date, start: missedClockIn.scheduledStart,
            scheduledStart: missedClockIn.scheduledStart, scheduledEnd: missedClockIn.scheduledEnd,
            holidayStatus: missedClockIn.holidayStatus)
        var checkedInReminder = AttendanceSnapshot(record: checkedIn, month: month, remainingWorkDays: 0, updatedAt: atStart)
        checkedInReminder.timeZone = reminderSnapshot.timeZone
        precondition(checkedInReminder.clockInReminderDate(mode: .scheduled, delayMinutes: 15) == nil)
        precondition(checkedInReminder.clockInReminderTime(mode: .scheduled, delayMinutes: 15) == "09:15")
        var unknownReminder = reminderSnapshot
        unknownReminder.attendanceKnown = false
        precondition(unknownReminder.clockInReminderTime(mode: .scheduled, delayMinutes: 15) == "--:--")
        precondition(AttendanceSnapshot(record: offDay, month: month, remainingWorkDays: 0, updatedAt: atStart)
            .clockInReminderTime(mode: .scheduled, delayMinutes: 15) == "알림 없음")
        precondition(!reminderSnapshot.shouldRemindToClockIn(at: beforeAverage, mode: .average, delayMinutes: 0))
        precondition(reminderSnapshot.shouldRemindToClockIn(at: atAverage, mode: .average, delayMinutes: 0))
        precondition(!reminderSnapshot.shouldRemindToClockIn(at: atAverage, mode: .average, delayMinutes: 15))
        precondition(!AttendanceSnapshot(record: offDay, month: month, remainingWorkDays: 0, updatedAt: Date()).shouldRemindToClockIn(at: atStart, mode: .scheduled, delayMinutes: 0))
        precondition(!AttendanceSnapshot(record: record, month: month, remainingWorkDays: 0, updatedAt: Date()).shouldRemindToClockIn(at: atStart, mode: .scheduled, delayMinutes: 0))
        precondition(AttendanceSnapshot.remainingScheduledDays(in: [today, tomorrowOff], during: month, today: "2026-09-29", at: morning) == 1)
        precondition(AttendanceSnapshot.remainingScheduledDays(in: [today, tomorrowOff], during: month, today: "2026-09-29", at: evening) == 0)
        precondition(AttendanceSnapshot.remainingScheduledDays(in: [finishedToday, tomorrowOff], during: month, today: "2026-09-29", at: morning) == 0)
        precondition(AttendanceSnapshot.remainingScheduledDays(in: [today, tomorrowOn], during: month, today: "2026-09-29", at: evening) == 1)
        let snapshot = AttendanceSnapshot(record: record, month: month, remainingWorkDays: 0, updatedAt: evening)
        precondition(snapshot.expectedMinutesByNow == 7920)
        precondition(snapshot.paceFraction == 1)
        precondition(snapshot.paceDifferenceMinutes == 744)
        precondition(snapshot.paceDescription == "빨간 선: 오늘까지 기준 132시간 0분")
        precondition(snapshot.overtimeMeter?.actualMinutes == 744)
        precondition(snapshot.overtimeMeter?.targetMinutes == 5451)
        precondition(snapshot.overtimeMeter?.percent == 14)
        precondition(snapshot.overtimeMeter?.fillFraction == Double(744) / 5451)
        let unfinishedMonth = MonthlyReport(workedMinutes: 7200, outsideMinutes: 0,
                                            requiredMinutes: 7920, vacationMinutes: 0,
                                            weekendMinutes: 0, dailyRequiredMinutes: 480,
                                            startDate: "2026-09-01", endDate: "2026-09-30",
                                            maximumWorkMinutes: 13371)
        precondition(AttendanceSnapshot(record: record, month: unfinishedMonth,
                                        remainingWorkDays: 2, updatedAt: Date()).overtimeMeter?.percent == 0)
        precondition(AttendanceSnapshot(record: record, month: unfinishedMonth,
                                        remainingWorkDays: 2, updatedAt: evening).paceDescription ==
                     "빨간 선: 오늘까지 기준 116시간 0분 · 4시간 0분 앞섬")
        precondition(AttendanceSnapshot(record: record, month: unfinishedMonth,
                                        remainingWorkDays: 1, updatedAt: evening).paceDescription ==
                     "빨간 선: 오늘까지 기준 124시간 0분 · 4시간 0분 부족")
        let monthMeter = WorkMeter(actualMinutes: month.actualMinutes, targetMinutes: month.targetMinutes)
        precondition(monthMeter.percent == 109)
        precondition(monthMeter.fillFraction == 1)
        let dayMeter = WorkMeter(actualMinutes: 240, targetMinutes: 480)
        precondition(dayMeter.fillFraction == 0.5)
        let minimumDay = DailyRecord(date: "2026-09-29", start: "2026-09-29T09:00:00+09:00",
                                    scheduledEnd: "2026-09-29T18:00:00+09:00", currentMinutes: 240,
                                    holidayStatus: "WEEKDAY_WORKING_ON_NONE_NONE")
        let minimumMonth = MonthlyReport(workedMinutes: 7200, outsideMinutes: 0,
                                         requiredMinutes: 7920, vacationMinutes: 0,
                                         weekendMinutes: 0, dailyRequiredMinutes: 480,
                                         startDate: "2026-09-01", endDate: "2026-09-30",
                                         maximumWorkMinutes: nil)
        let minimumSnapshot = AttendanceSnapshot(record: minimumDay, month: minimumMonth,
                                                 remainingWorkDays: 2, updatedAt: morning)
        // Today's 4 hours are included in the month: the daily goal stays 8 hours, not 6.
        precondition(minimumSnapshot.minimumTodayMeter?.targetMinutes == 480)
        precondition(minimumSnapshot.expectedMinutesByNow == 7440)
        // Extra work uses today's six-hour minimum, even before the month is in surplus.
        for minutes in [0, 240, 360, 440, 720, 900] {
            let day = DailyRecord(date: minimumDay.date, start: minimumDay.start,
                                  scheduledEnd: minimumDay.scheduledEnd, currentMinutes: minutes,
                                  holidayStatus: minimumDay.holidayStatus)
            let report = MonthlyReport(workedMinutes: 6960 + minutes, outsideMinutes: 0,
                                       requiredMinutes: 7680, vacationMinutes: 0,
                                       weekendMinutes: 0, dailyRequiredMinutes: 480,
                                       startDate: minimumMonth.startDate, endDate: minimumMonth.endDate,
                                       maximumWorkMinutes: 9600)
            let progress = AttendanceSnapshot(record: day, month: report,
                                              remainingWorkDays: 2, updatedAt: morning)
            let extra = max(0, minutes - 360)
            precondition(progress.minimumTodayMeter?.targetMinutes == 360)
            precondition(progress.minimumTodayOvertimeMinutes == extra)
            precondition(progress.menuTitle.contains(" · +") == (extra > 0))
            if minutes == 440 {
                precondition(progress.overtimeMeter?.actualMinutes == 0)
                precondition(progress.menuTitle == "근무 7시간 20분 · +1:20")
                let ended = DailyRecord(date: day.date, start: day.start,
                                        end: "2026-09-29T18:00:00+09:00", scheduledEnd: day.scheduledEnd,
                                        workedMinutes: minutes, holidayStatus: day.holidayStatus)
                let closed = AttendanceSnapshot(record: ended, month: report,
                                                remainingWorkDays: 1, updatedAt: evening)
                precondition(closed.menuTitle == "퇴근 7시간 20분 · +1:20")
                precondition(closed.minimumTodayMeter?.targetMinutes == 360)
                precondition(closed.minimumTodayOvertimeMinutes == 80)
            }
        }
        let firstDay = DailyRecord(date: "2026-10-01", start: "2026-10-01T10:10:00+09:00",
                                  scheduledEnd: "2026-10-01T18:00:00+09:00", currentMinutes: 19,
                                  holidayStatus: "WEEKDAY_WORKING_ON_NONE_NONE")
        let firstMonth = MonthlyReport(workedMinutes: 19, outsideMinutes: 0,
                                       requiredMinutes: 8640, vacationMinutes: 0,
                                       weekendMinutes: 0, dailyRequiredMinutes: 480,
                                       startDate: "2026-10-01", endDate: "2026-10-31",
                                       maximumWorkMinutes: nil)
        let firstSnapshot = AttendanceSnapshot(record: firstDay, month: firstMonth,
                                               remainingWorkDays: 18,
                                               updatedAt: ISO8601DateFormatter().date(from: "2026-10-01T10:29:00+09:00")!,
                                               dailyRestMinutes: 60)
        precondition(firstSnapshot.expectedMinutesByNow == 480)
        precondition(firstSnapshot.paceFraction == 1.0 / 18)
        precondition(firstSnapshot.attendanceDescription == "출근 10:10 · 예상 퇴근 19:10")
        precondition(reminderSnapshot.attendanceDescription == "출근 --:-- · 근무표 종료 18:00")
        precondition(AttendanceSnapshot(record: nil, month: firstMonth,
                                        remainingWorkDays: 18, updatedAt: morning).attendanceDescription == "오늘 기록 없음")
        var changedRest = firstSnapshot
        changedRest.dailyRestMinutes = 30
        precondition(changedRest.attendanceDescription == "출근 10:10 · 예상 퇴근 18:40")
        changedRest.dailyRestMinutes = 0
        precondition(changedRest.attendanceDescription == "출근 10:10 · 예상 퇴근 18:10")
        changedRest.dailyRestMinutes = nil
        precondition(changedRest.attendanceDescription == "출근 10:10")
        changedRest.dailyRestMinutes = -1
        precondition(changedRest.attendanceDescription == "출근 10:10")
        // The prediction uses the actual start and server-provided rest minutes.
        let lateStart = DailyRecord(date: "2026-10-01", start: "2026-10-01T23:30:00+09:00")
        precondition(AttendanceSnapshot(record: lateStart, month: firstMonth,
                                        remainingWorkDays: 18, updatedAt: morning, dailyRestMinutes: 60).attendanceDescription ==
                     "출근 23:30 · 예상 퇴근 08:30")
        let shorterDayMonth = MonthlyReport(workedMinutes: 0, outsideMinutes: 0,
                                            requiredMinutes: 360, vacationMinutes: 0,
                                            weekendMinutes: 0, dailyRequiredMinutes: 360,
                                            startDate: "2026-10-01", endDate: "2026-10-31",
                                            maximumWorkMinutes: nil)
        precondition(AttendanceSnapshot(record: firstDay, month: shorterDayMonth,
                                        remainingWorkDays: 1, updatedAt: morning, dailyRestMinutes: 60).attendanceDescription ==
                     "출근 10:10 · 예상 퇴근 17:10")
        let invalidStart = DailyRecord(date: firstDay.date, start: "invalid", scheduledEnd: firstDay.scheduledEnd)
        precondition(AttendanceSnapshot(record: invalidStart, month: firstMonth,
                                        remainingWorkDays: 18, updatedAt: morning, dailyRestMinutes: 60).attendanceDescription == "출근 --:--")
        let aheadMonth = MonthlyReport(workedMinutes: 7440, outsideMinutes: 0,
                                       requiredMinutes: 7920, vacationMinutes: 0,
                                       weekendMinutes: 0, dailyRequiredMinutes: 480,
                                       startDate: "2026-09-01", endDate: "2026-09-30",
                                       maximumWorkMinutes: nil)
        precondition(AttendanceSnapshot(record: minimumDay, month: aheadMonth,
                                        remainingWorkDays: 2, updatedAt: morning).expectedMinutesByNow == 7440)
        let laterDay = DailyRecord(date: minimumDay.date, start: minimumDay.start,
                                  scheduledEnd: minimumDay.scheduledEnd, currentMinutes: 360,
                                  holidayStatus: minimumDay.holidayStatus)
        let laterMonth = MonthlyReport(workedMinutes: 7320, outsideMinutes: 0,
                                       requiredMinutes: 7920, vacationMinutes: 0,
                                       weekendMinutes: 0, dailyRequiredMinutes: 480,
                                       startDate: "2026-09-01", endDate: "2026-09-30",
                                       maximumWorkMinutes: nil)
        precondition(AttendanceSnapshot(record: laterDay, month: laterMonth,
                                        remainingWorkDays: 2, updatedAt: morning).minimumTodayMeter?.targetMinutes == 480)
        precondition(AttendanceSnapshot(record: laterDay, month: laterMonth,
                                        remainingWorkDays: 2, updatedAt: morning).expectedMinutesByNow == 7440)
        // The goal is stable after the schedule ends or the employee clocks out.
        precondition(AttendanceSnapshot(record: minimumDay, month: minimumMonth,
                                        remainingWorkDays: 1, updatedAt: evening).minimumTodayMeter?.targetMinutes == 480)
        precondition(AttendanceSnapshot(record: minimumDay, month: minimumMonth,
                                        remainingWorkDays: 1, updatedAt: evening).expectedMinutesByNow == 7440)
        let endedDay = DailyRecord(date: minimumDay.date, start: minimumDay.start,
                                  end: "2026-09-29T13:00:00+09:00", scheduledEnd: minimumDay.scheduledEnd,
                                  workedMinutes: 240, holidayStatus: minimumDay.holidayStatus)
        precondition(AttendanceSnapshot(record: endedDay, month: minimumMonth,
                                        remainingWorkDays: 1, updatedAt: morning).attendanceDescription ==
                     "출근 09:00 · 퇴근 13:00")
        precondition(AttendanceSnapshot(record: endedDay, month: minimumMonth,
                                        remainingWorkDays: 1, updatedAt: morning).minimumTodayMeter?.targetMinutes == 480)
        precondition(AttendanceSnapshot(record: endedDay, month: minimumMonth,
                                        remainingWorkDays: 0, updatedAt: evening).minimumTodayMeter?.targetMinutes == 960)
        let unevenMonth = MonthlyReport(workedMinutes: 7199, outsideMinutes: 0,
                                        requiredMinutes: 7920, vacationMinutes: 0,
                                        weekendMinutes: 0, dailyRequiredMinutes: 480,
                                        startDate: "2026-09-01", endDate: "2026-09-30",
                                        maximumWorkMinutes: nil)
        precondition(AttendanceSnapshot(record: minimumDay, month: unevenMonth,
                                        remainingWorkDays: 2, updatedAt: morning).minimumTodayMeter?.targetMinutes == 481)
        let achieved = AttendanceSnapshot(record: minimumDay, month: month,
                                           remainingWorkDays: 2, updatedAt: morning)
        precondition(achieved.minimumTodayMeter?.targetMinutes == 0)
        precondition(achieved.minimumTodayOvertimeMinutes == 240)
        let noDays = AttendanceSnapshot(record: offDay, month: minimumMonth,
                                        remainingWorkDays: 0, updatedAt: evening)
        precondition(noDays.minimumTodayMeter == nil)
        precondition(noDays.minimumTodayOvertimeMinutes == 0)
        precondition(noDays.expectedMinutesByNow == minimumMonth.targetMinutes)
        let unevenSnapshot = AttendanceSnapshot(record: minimumDay, month: unevenMonth,
                                                remainingWorkDays: 2, updatedAt: morning)
        precondition(unevenSnapshot.remainingRequiredWorkDays == 2)
        precondition(unevenSnapshot.dailyRequiredHours == 721.0 / 2 / 60)
        precondition(noDays.remainingWorkDaysAfterToday == 0 && noDays.dailyRequiredHours == nil)
        precondition(achieved.dailyRequiredHours == 0)
        for (day, remainingDays, time, expectedDays) in [
            (minimumDay, 2, morning, 2), (minimumDay, 1, evening, 2),
            (missedClockIn, 2, morning, 2), (endedDay, 1, morning, 1), (offDay, 1, morning, 1)
        ] {
            let future = AttendanceSnapshot(record: day, month: minimumMonth,
                                            remainingWorkDays: remainingDays, updatedAt: time)
            precondition(future.remainingRequiredWorkDays == expectedDays)
            precondition(future.dailyRequiredHours == 12.0 / Double(expectedDays))
        }
        let lastDay = AttendanceSnapshot(record: minimumDay, month: minimumMonth,
                                          remainingWorkDays: 1, updatedAt: morning)
        precondition(lastDay.remainingRequiredWorkDays == 1 && lastDay.dailyRequiredHours == 12)
        let lastDayEnded = AttendanceSnapshot(record: endedDay, month: minimumMonth,
                                             remainingWorkDays: 0, updatedAt: evening)
        precondition(lastDayEnded.remainingRequiredWorkDays == 0 && lastDayEnded.dailyRequiredHours == nil)
        var unknown = minimumSnapshot
        unknown.attendanceKnown = false
        precondition(unknown.dailyRequiredHours == nil)
        precondition(snapshot.menuTitle == "근무 2시간 30분")
        precondition(AttendanceSnapshot.clock(record.scheduledEnd) == "18:00")
        precondition(AttendanceSnapshot.clock("2026-09-29 18:00:00") == "18:00")
        precondition(snapshot.todayMeter.actualMinutes == 150)
        precondition(snapshot.todayMeter.targetMinutes == 480)
        let shortDayMonth = MonthlyReport(workedMinutes: 8000, outsideMinutes: 0, requiredMinutes: 7920,
                                          vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 360,
                                          startDate: "2026-09-01", endDate: "2026-09-30", maximumWorkMinutes: nil)
        for (minutes, percent) in [(0, 0), (240, 50), (480, 100), (600, 125), (960, 200), (1200, 250)] {
            let day = DailyRecord(date: minimumDay.date, start: minimumDay.start,
                                  currentMinutes: minutes, holidayStatus: minimumDay.holidayStatus)
            var fixedDay = AttendanceSnapshot(record: day, month: shortDayMonth,
                                              remainingWorkDays: 0, updatedAt: evening)
            fixedDay.dailyTargetMinutes = 120
            precondition(fixedDay.todayMeter.targetMinutes == 480 && fixedDay.todayMeter.percent == percent,
                         "Daily progress must use eight hours even with short schedules or completed monthly requirements")
        }
        precondition(snapshot.monthMeter.actualMinutes == 8664)
        precondition(snapshot.monthMeter.targetMinutes == 7920)
        precondition(!SavedCookie(HTTPCookie(properties: [.name: "x", .value: "y", .domain: "example.com", .path: "/"])!).belongsToWantedSpace)
        precondition(SavedCookie(HTTPCookie(properties: [.name: "x", .value: "y", .domain: "api.handyspace.ai", .path: "/"])!).belongsToWantedSpace)
        precondition(!SavedCookie(HTTPCookie(properties: [.name: "x", .value: "y", .domain: "api.wantedspace.ai", .path: "/"])!).belongsToWantedSpace)
        let vaultService = "ai.wantedspace.WorkBar.Tests.\(UUID().uuidString)"
        let vault = KeychainSession(service: vaultService)
        defer { try? vault.delete() }
        let cookie = HTTPCookie(properties: [
            .name: "session-test", .value: "temporary-test-value",
            .domain: "api.handyspace.ai", .path: "/",
            .expires: Date().addingTimeInterval(3600)
        ])!
        let firstSave = try vault.save([cookie])
        let unchangedSave = try vault.save([cookie])
        precondition(firstSave && !unchangedSave)
        let restored = try vault.load()
        precondition(restored.first?.value == "temporary-test-value")
        let reopenedVault = KeychainSession(service: vaultService)
        _ = try reopenedVault.load()
        let unchangedAfterLoad = try reopenedVault.save([cookie])
        precondition(!unchangedAfterLoad)
        let refreshedCookie = HTTPCookie(properties: [
            .name: "session-test", .value: "refreshed-test-value",
            .domain: "api.handyspace.ai", .path: "/",
            .expires: cookie.expiresDate!
        ])!
        let refreshedSave = try reopenedVault.save([refreshedCookie])
        precondition(refreshedSave)
        let oldService = "ai.wantedspace.WorkBar.Tests.Old.\(UUID().uuidString)"
        let newService = "ai.wantedspace.WorkBar.Tests.New.\(UUID().uuidString)"
        let oldVault = KeychainSession(service: oldService)
        let newVault = KeychainSession(service: newService, legacyService: oldService)
        defer { try? oldVault.delete(); try? newVault.delete() }
        _ = try oldVault.save([cookie])
        let migrated = try newVault.load()
        let oldAfterMigration = try oldVault.load()
        let reopenedMigration = try KeychainSession(service: newService).load()
        precondition(migrated.first?.value == "temporary-test-value")
        precondition(oldAfterMigration.isEmpty)
        precondition(reopenedMigration.first?.value == "temporary-test-value")
        _ = try KeychainSession(service: oldService).save([cookie])
        try newVault.delete()
        let legacyAfterLogout = try oldVault.load()
        let currentAfterLogout = try newVault.load()
        precondition(legacyAfterLogout.isEmpty && currentAfterLogout.isEmpty)
        print("Core checks passed")
    }

    static func monthlyBaselineChecks() {
        let dates = ISO8601DateFormatter()
        for (actual, credited, today, difference) in [(4420, 4420, 420, -380), (6220, 5790, 544, 990)] {
            var month = MonthlyReport(workedMinutes: actual, outsideMinutes: 0, requiredMinutes: 8640,
                vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
                startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: nil)
            month.targetCreditedMinutes = credited
            for (end, time, remainingDays) in [(nil, "10:00:00", 9), (nil, "19:00:00", 8),
                                              ("2026-10-19T13:00:00+09:00", "14:00:00", 8)] {
                let record = DailyRecord(date: "2026-10-19", start: "2026-10-19T09:00:00+09:00", end: end,
                    scheduledEnd: "2026-10-19T18:00:00+09:00", workedMinutes: today, currentMinutes: today,
                    holidayStatus: "WEEKDAY_WORKING_ON_NONE_NONE")
                let snapshot = AttendanceSnapshot(record: record, month: month, remainingWorkDays: remainingDays,
                    updatedAt: dates.date(from: "2026-10-19T\(time)+09:00")!)
                precondition(snapshot.expectedMinutesByNow == 4800,
                             "The same schedule must use an 80-hour baseline regardless of accumulated work or clock-out")
                precondition(snapshot.paceDifferenceMinutes == difference)
            }
        }
    }

    static func leaveChecks() {
        let month = MonthlyReport(workedMinutes: 120, outsideMinutes: 0, requiredMinutes: 960,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: 1440)
        let today = try! JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-10-26","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE","wk_start_time":"2026-10-26T09:00:00+09:00","wk_end_time_sch":"2026-10-26T18:00:00+09:00","wk_time_min_now":120}"#.utf8))
        let future = try! JSONDecoder().decode(DailyRecord.self, from: Data(#"{"wk_date":"2026-10-27","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE"}"#.utf8))
        let updatedAt = ISO8601DateFormatter().date(from: "2026-10-26T20:00:00+09:00")!
        var raw = AttendanceSnapshot(record: today, month: month, remainingWorkDays: 1, updatedAt: updatedAt)
        raw.timeZone = TimeZone(identifier: "Asia/Seoul")!
        raw.calendarRecords = [today, future]
        raw.calendarRequiredMinutes = ["2026-10-25": 0, "2026-10-26": 480, "2026-10-27": 480, "2026-11-01": 480]
        raw.liveWorkClock = LiveWorkClock(start: raw.updatedAt.addingTimeInterval(-7200), completedMinutes: 0,
            rests: [], countsTowardTarget: true)
        raw.compensationEstimate = CompensationEstimate(month: month, days: [], holidays: [:])
        let paid = raw.applyingLeave(["2026-10-26": .paid, "2026-10-27": .unpaid, "2026-11-01": .paid])
        precondition(paid.month.requiredMinutes == 0 && paid.month.maximumWorkMinutes == 480)
        precondition(paid.compensationEstimate?.thresholdMinutes == 480)
        precondition(paid.remainingWorkDays == 0 && paid.dailyTargetMinutes == 0 && !paid.remindersAvailable)
        precondition(paid.todayMinutes == raw.todayMinutes && paid.month.workedMinutes == raw.month.workedMinutes)
        precondition(paid.leaveDeduction?.dates == ["2026-10-26", "2026-10-27"])
        precondition(paid.leaveDeduction?.minutes == 960 && paid.leaveDeduction?.maximumMinutes == 960)
        precondition(paid.remainingWorkDaysAfterToday == 0 && paid.minimumTodayMeter == nil)
        var holidaySnapshot = raw
        holidaySnapshot.calendarHolidays["2026-10-27"] = CompanyHoliday(name: "공휴일")
        let holidayLeave = holidaySnapshot.applyingLeave(["2026-10-27": .paid])
        precondition(holidayLeave.month.requiredMinutes == raw.month.requiredMinutes)
        precondition(holidayLeave.leaveByDate["2026-10-27"] == .paid && holidayLeave.leaveDeduction?.minutes == nil)
        let fullLeave = raw.applyingLeave(["2026-10-25": .paid])
        precondition(fullLeave.month.requiredMinutes == raw.month.requiredMinutes)
        precondition(fullLeave.leaveByDate["2026-10-25"] == .paid && fullLeave.leaveDeduction?.minutes == nil)
        var advanced = paid
        advanced.advanceLiveTime(to: raw.updatedAt.addingTimeInterval(60))
        precondition(advanced.todayMinutes == 121)
        precondition(raw.applyingLeave([:]).month.requiredMinutes == 960)
        let unpaid = raw.applyingLeave(["2026-10-27": .unpaid])
        precondition(unpaid.month.requiredMinutes == 480 && unpaid.compensationEstimate?.thresholdMinutes == 960)
        let ended = DailyRecord(date: today.date, start: today.start, end: "2026-10-26T12:00:00+09:00",
            scheduledEnd: today.scheduledEnd, workedMinutes: 120, holidayStatus: today.holidayStatus)
        var early = AttendanceSnapshot(record: ended, month: month, remainingWorkDays: 1,
            updatedAt: ISO8601DateFormatter().date(from: "2026-10-26T13:00:00+09:00")!)
        early.timeZone = raw.timeZone
        early.calendarRecords = [ended, future]
        early.calendarRequiredMinutes = raw.calendarRequiredMinutes
        let endedLeave = early.applyingLeave([today.date: .paid])
        precondition(endedLeave.remainingWorkDaysAfterToday == 1,
                     "A completed shift must not remove another future workday")
        precondition(endedLeave.record?.workedMinutes == 120 && endedLeave.record?.isScheduledWorkday == false)
    }
    static func flexAccountingChecks() throws {
        var month = MonthlyReport(workedMinutes: 4200, outsideMinutes: 0, requiredMinutes: 9600,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: 13812)
        month.targetCreditedMinutes = 3770
        precondition(month.actualMinutes == 4200 && month.remainingMinutes == 5830)
        var record = DailyRecord(date: "2026-10-15", start: "2026-10-15T09:53:00+09:00",
            scheduledEnd: "2026-10-15T18:53:00+09:00", currentMinutes: 144)
        record.scheduledWorkday = true
        var snapshot = AttendanceSnapshot(record: record, month: month, remainingWorkDays: 12,
            updatedAt: ISO8601DateFormatter().date(from: "2026-10-15T12:17:00+09:00")!)
        snapshot.todayCreditedMinutesInMonth = 0
        precondition(snapshot.minimumTodayMeter?.targetMinutes == 486)
        precondition(snapshot.expectedMinutesByNow == 4320)
        precondition(snapshot.monthMeter.actualMinutes == 3770)
        precondition(snapshot.overtimeMeter?.actualMinutes == 430)

        let cookie = HTTPCookie(properties: [.name: "session", .value: "test", .domain: ".flex.team",
            .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
        let other = HTTPCookie(properties: [.name: "session", .value: "other", .domain: "flex.team.example.com", .path: "/"])!
        precondition(SavedCookie(cookie).belongsTo(.flex) && !SavedCookie(cookie).belongsToWantedSpace)
        precondition(!SavedCookie(other).belongsTo(.flex))
        let service = "geuntae-flex-cookie-tests-\(UUID().uuidString)"
        let vault = KeychainSession(service: service, attendanceService: .flex)
        defer { try? vault.delete() }
        _ = try vault.save([cookie, other])
        let saved = try vault.load()
        precondition(saved.count == 1 && saved[0].cookie?.isHTTPOnly == true)
        let reopened = try KeychainSession(service: service, attendanceService: .flex).load()
        precondition(reopened == saved)
    }

    static func renewalChecks() async throws {
        let storage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "workbar-renewal-tests-\(UUID().uuidString)")
        func cookie(_ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: "auth-test", .value: value,
                                   .domain: "api.handyspace.ai", .path: "/"])!
        }
        storage.setCookie(cookie("old"))
        defer {
            AttendanceStubProtocol.onRequest = nil
            AttendanceStubProtocol.statuses = [:]
            for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
        }
        AttendanceStubProtocol.responses = [
            "/user/users/get_profile/": #"{"user_profile":{"user_id":1}}"#,
            "/v1/auth/refresh-token/": "{}",
            "/work/work_time/?date=2026-10-01": #"[{"wk_date":"2026-10-01","wk_start_time":"2026-10-01T09:00:00+09:00","wk_time_min_now":0}]"#,
            "/work/work_time/work_report/?date=2026-10-01": #"{"wk_time_week":0,"wk_out_min":0,"wk_time_recom":480,"wk_vac_min":0,"wk_weekend_min":0,"cont_work_day":480,"start_date":"2026-10-01","end_date":"2026-10-31"}"#,
            "/work/sch_event/company_holidays/": "{}"
        ]
        var profileCookies: [String] = []
        var renewals = 0
        AttendanceStubProtocol.onRequest = { request in
            if request.url!.path.contains("get_profile") {
                let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
                profileCookies.append(header)
                AttendanceStubProtocol.statuses["/user/users/get_profile/"] = header.contains("auth-test=new") ? 200 : 401
            } else if request.url!.path.contains("refresh-token") {
                renewals += 1
                storage.setCookie(cookie("new"))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttendanceStubProtocol.self]
        let client = AttendanceClient(cookies: storage, configuration: configuration)
        _ = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-01T12:00:00+09:00")!)
        precondition(renewals == 1 && profileCookies.count == 2)
        precondition(profileCookies[0].contains("auth-test=old") && profileCookies[1].contains("auth-test=new"))
        print("Session renewal checks passed")
    }

    static func overnightChecks() async throws {
        let storage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "workbar-overnight-tests-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttendanceStubProtocol.self]
        let client = AttendanceClient(cookies: storage, configuration: configuration)
        let rows = #"[{"wk_date":"2026-10-03","wk_start_time_sch":"2026-10-03T09:00:00+09:00","wk_end_time_sch":"2026-10-03T18:00:00+09:00","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE"},{"wk_date":"2026-10-02","wk_start_time":"2026-10-02T15:00:00+09:00","wk_end_time":null,"wk_end_time_sch":"2026-10-02T18:00:00+09:00","wk_time_min":10,"wk_time_min_now":510,"evt_out_min":30,"wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE"},{"wk_date":"2026-10-04","wk_start_time":"2026-10-04T09:00:00+09:00","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE"},{"wk_date":"2026-10-01","wk_start_time":"2026-10-01T09:00:00+09:00","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE"}]"#
        let report = #"{"wk_time_week":510,"wk_out_min":30,"wk_time_recom":1440,"wk_vac_min":0,"wk_weekend_min":0,"cont_work_day":480,"start_date":"2026-10-01","end_date":"2026-10-31"}"#
        AttendanceStubProtocol.responses = [
            "/user/users/get_profile/": #"{"user_profile":{"user_id":1,"wk_except_legal":30}}"#,
            "/work/work_time/?date=2026-10-02": rows,
            "/work/work_time/?date=2026-10-03": rows,
            "/work/work_time/work_report/?date=2026-10-02": report,
            "/work/work_time/work_report/?date=2026-10-03": report,
            "/work/sch_event/company_holidays/": #"{"2026-10-05":{"name":"창립기념일"}}"#
        ]
        let before = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-02T23:59:00+09:00")!)
        AttendanceStubProtocol.requests = []
        let after = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-03T00:01:00+09:00")!)
        precondition(after.record?.date == "2026-10-02", "An unfinished shift must keep its clock-in date")
        precondition(after.calendarRecords.map(\.date) == ["2026-10-03", "2026-10-02", "2026-10-04", "2026-10-01"])
        precondition(after.calendarRecords.first { $0.date == "2026-10-02" }?.start == "2026-10-02T15:00:00+09:00")
        precondition(after.calendarRecords.first { $0.date == "2026-10-02" }?.isScheduledWorkday == true)
        precondition(after.calendarHolidays["2026-10-05"]?.name == "창립기념일")
        precondition(before.dailyRestMinutes == 30 && after.dailyRestMinutes == 30)
        precondition(after.attendanceDescription == "출근 15:00 · 예상 퇴근 23:30")
        precondition(before.dayTitle == "오늘" && after.dayTitle == "2026-10-02")
        precondition(after.monthTitle == "이번 달")
        precondition(before.todayMinutes == 540 && after.todayMinutes == 540)
        precondition(after.minimumTodayMeter?.targetMinutes == before.minimumTodayMeter?.targetMinutes)
        precondition(after.expectedMinutesByNow == before.expectedMinutesByNow)
        precondition(after.remainingWorkDays == 2)
        precondition(after.calendarRequiredMinutes["2026-10-03"] == 480)
        let wantedLeave = after.applyingLeave(["2026-10-03": .paid])
        precondition(wantedLeave.leaveDeduction?.dates == ["2026-10-03"])
        precondition(wantedLeave.leaveDeduction?.minutes == 480)
        precondition(wantedLeave.month.requiredMinutes == after.month.requiredMinutes - 480)
        precondition(wantedLeave.calendarRecords.first { $0.date == "2026-10-03" }?.isScheduledWorkday == false)
        precondition(wantedLeave.remainingWorkDaysAfterToday == after.remainingWorkDaysAfterToday - 1)
        precondition(after.applyingLeave([:]).month.requiredMinutes == after.month.requiredMinutes)
        precondition(!after.shouldRemindToClockIn(at: ISO8601DateFormatter().date(from: "2026-10-03T10:00:00+09:00")!,
                                                 mode: .scheduled, delayMinutes: 0))
        precondition(AttendanceStubProtocol.requests.contains("/work/work_time/work_report/?date=2026-10-02"))
        precondition(!AttendanceStubProtocol.requests.contains { $0.contains("date=2026-09") })

        // Each refresh uses the server's minutes, without estimating elapsed time locally.
        AttendanceStubProtocol.responses["/work/work_time/?date=2026-10-03"] = rows
            .replacingOccurrences(of: "\"wk_time_min_now\":510", with: "\"wk_time_min_now\":520")
        AttendanceStubProtocol.responses["/work/work_time/work_report/?date=2026-10-02"] = report
            .replacingOccurrences(of: "\"wk_time_week\":510", with: "\"wk_time_week\":520")
        let synced = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-03T00:06:00+09:00")!)
        precondition(synced.todayMinutes == 550 && synced.month.actualMinutes == 550)
        precondition(synced.minimumTodayMeter?.targetMinutes == before.minimumTodayMeter?.targetMinutes)

        // A completed newer shift must not revive an older missed clock-out.
        AttendanceStubProtocol.responses["/work/work_time/?date=2026-10-03"] = rows
            .replacingOccurrences(of: "\"wk_end_time\":null", with: "\"wk_end_time\":\"2026-10-03T00:10:00+09:00\"")
        let ended = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-03T00:11:00+09:00")!)
        precondition(ended.record?.date == "2026-10-03" && ended.todayMinutes == 0)
        precondition(ended.record?.isWorking == false)
        precondition(ended.dayTitle == "오늘")

        // The previous month is required even when average-clock-in reminders are disabled.
        let previousRows = #"[{"wk_date":"2026-09-30","wk_start_time":"2026-09-30T15:00:00+09:00","wk_end_time":null,"wk_end_time_sch":"2026-09-30T18:00:00+09:00","wk_time_min_now":540,"wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE"},{"wk_date":"2026-09-02","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE"}]"#
        let previousReport = #"{"wk_time_week":7740,"wk_out_min":0,"wk_time_recom":7920,"wk_vac_min":0,"wk_weekend_min":0,"cont_work_day":480,"start_date":"2026-09-01","end_date":"2026-09-30"}"#
        let newMonthRows = #"[{"wk_date":"2026-10-01","wk_holiday":"WEEKDAY_WORKING_ON_NONE_NONE","wk_end_time_sch":"2026-10-01T18:00:00+09:00"}]"#
        AttendanceStubProtocol.responses["/work/work_time/?date=2026-10-01"] = newMonthRows
        AttendanceStubProtocol.responses["/work/work_time/?date=2026-09-01"] = previousRows
        AttendanceStubProtocol.responses["/work/work_time/work_report/?date=2026-10-01"] = report
        AttendanceStubProtocol.responses["/work/work_time/work_report/?date=2026-09-30"] = previousReport
        AttendanceStubProtocol.responses["/work/sch_event/company_holidays/"] = #"{"2026-09-02":{"name":"사내 리프레시 데이"}}"#
        AttendanceStubProtocol.requests = []
        let monthBoundary = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-01T00:01:00+09:00")!)
        precondition(monthBoundary.record?.date == "2026-09-30" && monthBoundary.todayMinutes == 540)
        precondition(monthBoundary.dayTitle == "2026-09-30" && monthBoundary.monthTitle == "2026-09")
        precondition(monthBoundary.paceDescription.contains("2026-09-30까지 기준"))
        precondition(monthBoundary.month.startDate == "2026-09-01" && monthBoundary.month.actualMinutes == 7740)
        precondition(monthBoundary.remainingWorkDays == 0 && monthBoundary.minimumTodayMeter?.targetMinutes == 720)
        precondition(monthBoundary.compensationEstimate?.refreshDays == 1)
        precondition(AttendanceStubProtocol.requests.contains("/work/work_time/?date=2026-09-01"))
        precondition(AttendanceStubProtocol.requests.contains("/work/work_time/work_report/?date=2026-09-30"))

        AttendanceStubProtocol.responses["/work/work_time/?date=2026-09-01"] = previousRows
            .replacingOccurrences(of: "\"wk_end_time\":null", with: "\"wk_end_time\":\"2026-10-01T00:10:00+09:00\"")
        let newMonth = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-01T00:11:00+09:00")!)
        precondition(newMonth.record?.date == "2026-10-01" && newMonth.month.startDate == "2026-10-01")
        precondition(newMonth.dayTitle == "오늘" && newMonth.monthTitle == "이번 달")
        precondition(newMonth.compensationEstimate?.refreshDays == 0)

        // A failed required lookup must leave the app's previous snapshot intact.
        AttendanceStubProtocol.statuses["/work/work_time/?date=2026-09-01"] = 503
        do {
            _ = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-01T00:16:00+09:00")!)
            preconditionFailure("A required previous-month lookup must not silently reset the shift")
        } catch AttendanceError.httpStatus(let status, _) {
            precondition(status == 503)
        }
        AttendanceStubProtocol.statuses = [:]

        // Average-clock-in history remains optional when this month's attendance is known.
        AttendanceStubProtocol.responses["/work/work_time/?date=2026-10-03"] = rows
        AttendanceStubProtocol.responses["/work/work_time/?date=2026-09-03"] = "[]"
        AttendanceStubProtocol.statuses["/work/work_time/?date=2026-09-03"] = 503
        let optionalHistory = try await client.snapshot(for: ISO8601DateFormatter().date(from: "2026-10-03T00:16:00+09:00")!,
                                                        includePreviousMonth: true)
        precondition(optionalHistory.record?.date == "2026-10-02")
        AttendanceStubProtocol.statuses = [:]
        print("Overnight synchronization checks passed")
    }
}
