import Foundation

final class FlexStubProtocol: URLProtocol {
    static var handler: (URLRequest) throws -> (Int, Data, [String: String]) = { _ in fatalError("Missing response") }
    static var requests: [URLRequest] = []
    static var hold = false
    static var delayed: FlexStubProtocol?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "flex.team" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if Self.hold { Self.delayed = self; return }
        do {
            let (status, data, headers) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
@MainActor
struct FlexTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/flex-web.json")
    static func fixture() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any] }
    static func decode<T: Decodable>(_ key: String, from data: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: data[key]!))
    }
    static func snapshot(_ f: [String: Any], customHoliday: CustomHolidayRule? = nil,
                         serverClockOffset: TimeInterval = 0) throws -> AttendanceSnapshot {
        let period: FlexPeriodResponse = try decode("period", from: f)
        let rules: FlexRules = try decode("rules", from: f)
        let schedules: FlexSchedules = try decode("schedules", from: f)
        let dates: FlexDayAttributes = try decode("attributes", from: f)
        return try FlexAttendance.snapshot(period: period.period, summary: decode("summary", from: f),
            today: decode("today", from: f), status: decode("status", from: f),
            schedules: schedules.dailySchedules, attributes: dates.workingDayAttributes, rule: rules.workRules[0],
            customHoliday: customHoliday, serverClockOffset: serverClockOffset)
    }
    static func cookie(_ name: String = "JSESSIONID", domain: String = "flex.team", path: String = "/") -> SavedCookie {
        SavedCookie(HTTPCookie(properties: [.name: name, .value: "test-session", .domain: domain, .path: path, .secure: "TRUE"])!)
    }
    static func client() -> FlexClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlexStubProtocol.self]
        let client = FlexClient(configuration: configuration, requestInterval: 0)
        client.restore([cookie()])
        return client
    }
    static func main() async throws {
        try attendanceChecks()
        try customHolidayChecks()
        try await requestChecks()
        try await fetchingChecks()
        print("Flex web API checks passed")
    }
    static func attendanceChecks() throws {
        let f = try fixture()
        var history = f
        var historyDays = history["schedules"] as! [String: Any]
        historyDays["dailySchedules"] = [f["historySchedule"]!] + (historyDays["dailySchedules"] as! [Any])
        history["schedules"] = historyDays
        var historyDates = history["attributes"] as! [String: Any]
        historyDates["workingDayAttributes"] = [f["historyAttribute"]!] + (historyDates["workingDayAttributes"] as! [Any])
        history["attributes"] = historyDates
        let withAnnualLeave = try snapshot(history)
        precondition(withAnnualLeave.todayMinutes == 144 && withAnnualLeave.month.actualMinutes == 4200)
        let live = try snapshot(f)
        let offsetSnapshot = try snapshot(f, serverClockOffset: 3600)
        precondition(offsetSnapshot.todayMinutes == live.todayMinutes &&
                     offsetSnapshot.attendanceNote == live.attendanceNote)
        precondition(live.month.actualMinutes == 4200 && live.month.creditedMinutes == 3770)
        precondition(live.month.remainingMinutes == 5830 && live.month.targetMinutes == 9600)
        precondition(live.month.maximumWorkMinutes == 13812 && live.overtimeMeter?.actualMinutes == 430)
        precondition(live.todayMinutes == 144 && live.todayCreditedMinutesInMonth == 0)
        precondition(live.record?.isWorking == true && live.attendanceDescription.contains("09:53"))
        precondition(live.attendanceDescription.contains("18:53") && live.remainingWorkDays == 12)
        precondition(live.minimumTodayMeter?.targetMinutes == 486 && live.monthMeter.percent == 41)
        precondition(live.displayMonth.actualMinutes == 4344 && live.displayMonth.creditedMinutes == 3914)
        precondition(live.displayMonth.remainingMinutes == 5686 && live.displayCompensationEstimate?.remainingMinutes == 5686)
        var partlyFinalized = live
        partlyFinalized.liveWorkClock = LiveWorkClock(start: live.liveWorkClock!.start.addingTimeInterval(3600),
            completedMinutes: 60, rests: live.liveWorkClock!.rests, countsTowardTarget: true)
        precondition(partlyFinalized.ongoingMinutes == 84 && partlyFinalized.displayMonth.actualMinutes == 4284)
        precondition(live.clockInReminderTime(mode: .scheduled, delayMinutes: 0) == "10:00")
        let stamp: (String) throws -> Double = { try FlexDates.parse($0).timeIntervalSince1970 * 1000 }
        func at(_ time: String, change: ((inout [String: Any]) -> Void)? = nil) throws -> [String: Any] {
            var copy = f, status = copy["status"] as! [String: Any]
            status["requestedAt"] = try stamp(time.contains("T") ? time : "2026-10-15T" + time)
            change?(&status)
            copy["status"] = status
            return copy
        }
        let resting = try snapshot(at("13:30:00"))
        precondition(resting.todayMinutes == 187 && resting.attendanceNote?.hasPrefix("휴게 중") == true)
        let resumed = try snapshot(at("14:30:00"))
        precondition(resumed.todayMinutes == 217 && resumed.month.actualMinutes == 4200)
        precondition(resumed.minimumTodayMeter?.targetMinutes == live.minimumTodayMeter?.targetMinutes)
        var ticking = live
        ticking.advanceLiveTime(to: live.updatedAt.addingTimeInterval(60))
        precondition(ticking.todayMinutes == 145 && ticking.menuTitle.contains("2시간 25분"))
        precondition(ticking.minimumTodayFill > live.minimumTodayFill)
        precondition(ticking.updatedAt == live.updatedAt && ticking.month.actualMinutes == 4200)
        precondition(ticking.month.creditedMinutes == 3770 && ticking.minimumTodayMeter?.targetMinutes == 486)
        precondition(ticking.displayMonth.actualMinutes == 4345 && ticking.monthMeter.actualMinutes == 3915)
        ticking.advanceLiveTime(to: try FlexDates.parse("2026-10-15T13:30:00"))
        precondition(ticking.todayMinutes == resting.todayMinutes && ticking.attendanceNote == resting.attendanceNote)
        ticking.advanceLiveTime(to: try FlexDates.parse("2026-10-15T13:59:59"))
        precondition(ticking.todayMinutes == 187)
        precondition(ticking.displayMonth.actualMinutes == 4387)
        ticking.advanceLiveTime(to: try FlexDates.parse("2026-10-15T14:30:00"))
        precondition(ticking.todayMinutes == resumed.todayMinutes && ticking.attendanceNote == resumed.attendanceNote)
        ticking.advanceLiveTime(to: live.updatedAt)
        precondition(ticking.todayMinutes == 217)
        var openRest = try at("13:30:00")
        var openStatus = openRest["status"] as! [String: Any]
        var openPack = openStatus["onGoingRecordPack"] as! [String: Any]
        var openRests = openPack["restRecords"] as! [[String: Any]]
        openRests[0]["restStopRecord"] = NSNull()
        openPack["restRecords"] = openRests; openStatus["onGoingRecordPack"] = openPack; openRest["status"] = openStatus
        var paused = try snapshot(openRest)
        paused.advanceLiveTime(to: try FlexDates.parse("2026-10-15T14:30:00"))
        precondition(paused.todayMinutes == 187 && paused.attendanceNote?.hasPrefix("휴게 중") == true)
        var duplicate = try at("14:30:00")
        var status = duplicate["status"] as! [String: Any], pack = status["onGoingRecordPack"] as! [String: Any]
        pack["restRecords"] = (pack["restRecords"] as! [[String: Any]]) + (pack["restRecords"] as! [[String: Any]])
        status["onGoingRecordPack"] = pack; duplicate["status"] = status
        let deduplicated = try snapshot(duplicate)
        precondition(deduplicated.todayMinutes == resumed.todayMinutes)
        let overnight = try snapshot(at("2026-10-16T01:00:00"))
        precondition(overnight.record?.date == "2026-10-15" && overnight.todayMinutes == 847)
        var boundary = f
        status = boundary["status"] as! [String: Any]
        pack = status["onGoingRecordPack"] as! [String: Any]
        pack["startRecord"] = ["eventType": "START", "recordType": "RECORD", "targetTime": try stamp("2026-10-31T23:00:00")]
        pack["restRecords"] = []
        status["onGoingRecordPack"] = pack
        status["targetDate"] = "2026-11-01"
        status["requestedAt"] = try stamp("2026-11-01T01:00:00")
        boundary["status"] = status
        let lastMonth = try snapshot(boundary)
        precondition(lastMonth.record?.date == "2026-10-31" && lastMonth.todayMinutes == 120 && lastMonth.month.startDate == "2026-10-01")
        precondition(lastMonth.displayMonth.actualMinutes == 4320 && lastMonth.displayMonth.creditedMinutes == 3770)
        precondition(lastMonth.overtimeMeter?.actualMinutes == 550)

        var closed = f
        status = closed["status"] as! [String: Any]
        status["onGoingRecordPack"] = NSNull()
        status["targetDate"] = "2026-10-13"
        status["requestedAt"] = try stamp("2026-10-13T20:00:00")
        closed["status"] = status
        closed["today"] = ["totalActualWorkingMinutes": 481, "totalRecognizedWorkingMinutes": 481]
        let finished = try snapshot(closed)
        precondition(finished.todayMinutes == 481 && finished.record?.isWorking == false && !finished.isEstimated)
        precondition(finished.todayCreditedMinutesInMonth == 481 && finished.month.actualMinutes == 4200)
        var stopped = finished
        stopped.advanceLiveTime(to: finished.updatedAt.addingTimeInterval(120))
        precondition(stopped.todayMinutes == finished.todayMinutes && stopped.liveWorkClock == nil)

        func rejected(_ copy: [String: Any]) throws {
            do { _ = try snapshot(copy); preconditionFailure("Inconsistent responses must not become zero work") }
            catch FlexError.inconsistent {}
        }
        var incomplete = f
        status = incomplete["status"] as! [String: Any]
        pack = status["onGoingRecordPack"] as! [String: Any]
        pack["onGoing"] = false
        pack["stopRecord"] = ["eventType": "STOP", "recordType": "RECORD", "targetTime": try stamp("2026-10-15T12:00:00")]
        status["onGoingRecordPack"] = pack; incomplete["status"] = status
        try rejected(incomplete)
        var completed = incomplete
        status = completed["status"] as! [String: Any]
        status["requestedAt"] = try stamp("2026-10-15T19:00:00")
        completed["status"] = status
        completed["today"] = ["totalActualWorkingMinutes": 480, "totalRecognizedWorkingMinutes": 480]
        var periodSummary = completed["summary"] as! [String: Any], result = periodSummary["result"] as! [String: Any]
        result["currentTargetWorkingMinutes"] = 4250; result["totalRecognizedWorkingMinutes"] = 4680
        periodSummary["result"] = result; completed["summary"] = periodSummary
        var completedSchedules = completed["schedules"] as! [String: Any]
        var completedDays = completedSchedules["dailySchedules"] as! [[String: Any]]
        let todayIndex = completedDays.firstIndex { $0["date"] as? String == "2026-10-15" }!
        func block(_ type: String, _ from: String, _ to: String) throws -> [String: Any] {
            ["type": type, "value": ["startTimestamp": ["timestamp": try stamp("2026-10-15T" + from)],
                "endTimestampExclusive": ["timestamp": try stamp("2026-10-15T" + to)], "eventStatus": "RECORD", "allDay": false]]
        }
        completedDays[todayIndex]["timeBlocks"] = try [block("WORK", "09:53:00", "18:53:00"), block("REST", "13:00:00", "14:00:00")]
        completedSchedules["dailySchedules"] = completedDays; completed["schedules"] = completedSchedules
        let clockedOut = try snapshot(completed)
        precondition(!clockedOut.record!.isWorking && clockedOut.todayMinutes == 480)
        precondition(clockedOut.minimumTodayMeter?.targetMinutes == live.minimumTodayMeter?.targetMinutes)
        precondition(clockedOut.month.actualMinutes == 4680 && clockedOut.todayCreditedMinutesInMonth == 480)
        var beforeClockOut = live
        beforeClockOut.advanceLiveTime(to: try FlexDates.parse("2026-10-15T18:53:00"))
        precondition(beforeClockOut.displayMonth.actualMinutes == clockedOut.displayMonth.actualMinutes)
        precondition(beforeClockOut.displayMonth.creditedMinutes == clockedOut.displayMonth.creditedMinutes)
        completedDays[todayIndex]["timeBlocks"] = try [block("WORK", "09:53:00", "18:53:00"), block("WORK", "10:00:00", "11:00:00")]
        completedSchedules["dailySchedules"] = completedDays; completed["schedules"] = completedSchedules
        try rejected(completed)
        var missing = f, dates = missing["attributes"] as! [String: Any]
        dates["workingDayAttributes"] = Array((dates["workingDayAttributes"] as! [[String: Any]]).dropFirst())
        missing["attributes"] = dates
        try rejected(missing)

        var leave = f
        status = leave["status"] as! [String: Any]
        status["onGoingRecordPack"] = NSNull(); leave["status"] = status
        var schedule = leave["schedules"] as! [String: Any], days = schedule["dailySchedules"] as! [[String: Any]]
        let index = days.firstIndex { $0["date"] as? String == "2026-10-15" }!
        days[index]["timeBlocks"] = [["type": "TIME_OFF", "value": ["allDay": true]]]
        schedule["dailySchedules"] = days; leave["schedules"] = schedule
        let fullLeave = try snapshot(leave)
        precondition(fullLeave.record?.isScheduledWorkday == false)
        precondition(fullLeave.clockInReminderDate(mode: .scheduled, delayMinutes: 0) == nil)
        days[index]["timeBlocks"] = [["type": "TIME_OFF", "value": ["allDay": false]]]
        schedule["dailySchedules"] = days; leave["schedules"] = schedule
        let unknownLeave = try snapshot(leave)
        precondition(!unknownLeave.remindersAvailable)
        days[index]["timeBlocks"] = try [block("TIME_OFF", "10:00:00", "14:00:00")]
        schedule["dailySchedules"] = days; leave["schedules"] = schedule
        let partialLeave = try snapshot(leave)
        precondition(partialLeave.clockInReminderTime(mode: .scheduled, delayMinutes: 0) == "14:00")
        var annual = f["historySchedule"] as! [String: Any]
        annual["date"] = "2026-10-15"
        days[index] = annual; schedule["dailySchedules"] = days; leave["schedules"] = schedule
        let flexibleHalfDay = try snapshot(leave)
        precondition(!flexibleHalfDay.remindersAvailable && flexibleHalfDay.dailyTargetMinutes == 240)
    }
    static func customHolidayChecks() throws {
        let f = try fixture()
        // 1st/3rd/5th Wednesday: 10-07 (already worked) and 10-21; October has no 5th Wednesday.
        let wednesdays = try snapshot(f, customHoliday: CustomHolidayRule(weekday: 4, ordinals: [1, 3, 5]))
        precondition(wednesdays.month.targetMinutes == 9600 - 960 && wednesdays.month.creditedMinutes == 3770)
        precondition(wednesdays.month.maximumWorkMinutes == 13812 - 960)
        let unpaid = try snapshot(f, customHoliday: CustomHolidayRule(weekday: 4, ordinals: [1, 3, 5], affectsCompensation: false))
        precondition(unpaid.month.targetMinutes == 9600 - 960 && unpaid.compensationEstimate?.thresholdMinutes == 9600)
        precondition(wednesdays.compensationEstimate?.thresholdMinutes == 9600 - 960)
        let paidOnly = try snapshot(f, customHoliday: CustomHolidayRule(weekday: 4, ordinals: [1, 3, 5],
            affectsRequired: false, affectsMaximum: false))
        precondition(paidOnly.month.targetMinutes == 9600 && paidOnly.month.maximumWorkMinutes == 13812)
        precondition(paidOnly.compensationEstimate?.thresholdMinutes == 9600 - 960)
        precondition(paidOnly.customHolidayDeduction?.maximumMinutes == 0 && paidOnly.remainingWorkDays == 11)
        let legacy = try JSONDecoder().decode(CustomHolidayRule.self, from: Data(#"{"weekday":4,"ordinals":[1]}"#.utf8))
        precondition(legacy.affectsRequired && legacy.affectsMaximum && legacy.affectsCompensation)
        let deduction = wednesdays.customHolidayDeduction!
        precondition(deduction.dates == ["2026-10-07", "2026-10-21"] && deduction.minutes == 960)
        precondition(deduction.flexRequiredMinutes == 9600 && deduction.flexMaximumMinutes == 13812)
        let plain = try snapshot(f)
        precondition(plain.customHolidayDeduction == nil)
        precondition(wednesdays.remainingWorkDays == 11)
        let today = try snapshot(f, customHoliday: CustomHolidayRule(weekday: 5, ordinals: [3]))
        precondition(today.record?.isScheduledWorkday == false && today.month.targetMinutes == 9600 - 480)
        precondition(today.clockInReminderDate(mode: .scheduled, delayMinutes: 0) == nil)
        var history = f
        var historyDays = history["schedules"] as! [String: Any]
        historyDays["dailySchedules"] = [f["historySchedule"]!] + (historyDays["dailySchedules"] as! [Any])
        history["schedules"] = historyDays
        var historyDates = history["attributes"] as! [String: Any]
        historyDates["workingDayAttributes"] = [f["historyAttribute"]!] + (historyDates["workingDayAttributes"] as! [Any])
        history["attributes"] = historyDates
        // 09-04 is outside the period and 10-09 is already a flex holiday, so only 10-02 is deducted.
        let fridays = try snapshot(history, customHoliday: CustomHolidayRule(weekday: 6, ordinals: [1, 2]))
        precondition(fridays.month.targetMinutes == 9600 - 480)
    }
    static func requestChecks() async throws {
        FlexStubProtocol.requests = []
        let api = client()
        api.restore([cookie(), cookie("sub", domain: "accounts.flex.team"), cookie("path", path: "/other"), cookie("foreign", domain: "example.com")])
        FlexStubProtocol.handler = { request in
            precondition(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "Cookie") == "JSESSIONID=test-session")
            return (200, Data("{}".utf8), ["Set-Cookie": "JSESSIONID=rotated; Path=/; Secure; HttpOnly"])
        }
        _ = try await api.get("/api/v2/workspace/users/me/workspace-users")
        precondition(api.currentCookies().contains { $0.value == "rotated" && $0.isHTTPOnly })
        for code in [401, 403, 429, 302, 500] {
            let test = client()
            FlexStubProtocol.handler = { _ in (code, Data("{}".utf8), ["Retry-After": "1"]) }
            do { _ = try await test.get("/api/v2/test"); preconditionFailure("HTTP errors must fail") }
            catch let error as FlexError {
                switch (code, error) {
                case (401, .authentication), (302, .authentication), (403, .permissionDenied), (429, .rateLimited), (500, .httpStatus(500)): break
                default: preconditionFailure("Wrong error")
                }
            }
        }
        FlexStubProtocol.handler = { _ in (200, Data("<html>sign in</html>".utf8), ["Content-Type": "text/html"]) }
        do { _ = try await client().get("/api/v2/test"); preconditionFailure("HTML must not become attendance") }
        catch FlexError.inconsistent {}
        let pending = client()
        FlexStubProtocol.hold = true
        let task = Task { try await pending.get("/api/v2/test") }
        while FlexStubProtocol.delayed == nil { await Task.yield() }
        pending.clearCookies()
        do { _ = try await task.value; preconditionFailure("Cancelled response must not restore cookies") }
        catch {}
        precondition(pending.currentCookies().isEmpty)
        FlexStubProtocol.hold = false; FlexStubProtocol.delayed = nil
    }
    static func fetchingChecks() async throws {
        let f = try fixture()
        FlexStubProtocol.requests = []
        FlexStubProtocol.handler = { request in
            let path = request.url!.path
            let key: String
            switch path {
            case "/api/v2/workspace/users/me/workspace-users": key = "identity"
            case "/api/v2/time-tracking/current-time": key = "serverTime"
            case let p where p.hasSuffix("/current-status"): key = "status"
            case let p where p.hasSuffix("/working-periods/now"): key = "period"
            case let p where p.hasSuffix("/summary/by-working-period"): key = "summary"
            case let p where p.hasSuffix("/summary/by-date-range"):
                precondition(request.url!.query!.contains("from=2026-10-15&to=2026-10-15")); key = "today"
            case let p where p.hasSuffix("/work-schedules"): key = "schedules"
            case let p where p.hasSuffix("/date-attributes"): key = "attributes"
            case let p where p.hasSuffix("/work-rules/by-date/2026-10-15"): key = "userRule"
            case let p where p.hasSuffix("/work-rules/101"): key = "rules"
            default: preconditionFailure("Unexpected path: \(path)")
            }
            var payload = f[key]!
            if key == "schedules" || key == "attributes" {
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let from = items.first { $0.name == "from" }!.value!, to = items.first { $0.name == "to" }!.value!
                var container = payload as! [String: Any]
                let arrayKey = key == "schedules" ? "dailySchedules" : "workingDayAttributes"
                let historical = f[key == "schedules" ? "historySchedule" : "historyAttribute"] as! [String: Any]
                container[arrayKey] = ([historical] + (container[arrayKey] as! [[String: Any]])).filter {
                    let date = $0["date"] as! String
                    return date >= from && date <= to
                }
                payload = container
            }
            return (200, try JSONSerialization.data(withJSONObject: payload), [:])
        }
        let before = Date()
        let fetcher = client()
        let result = try await fetcher.snapshot()
        let after = Date()
        let serverTime: FlexServerTime = try decode("serverTime", from: f)
        let serverDate = try FlexDates.timestamp(serverTime.timeStamp)
        precondition(result.serverClockOffset <= serverDate.timeIntervalSince(before))
        precondition(result.serverClockOffset >= serverDate.timeIntervalSince(after))
        precondition(result.accountIdentifier == "company-1:user-1" && result.todayMinutes == 144)
        precondition(FlexStubProtocol.requests.count == 10)
        // Changing the custom holiday recomputes from the fetched data without waiting on rate-limited requests.
        FlexStubProtocol.requests = []
        let rebuilt = try fetcher.rebuild(customHoliday: CustomHolidayRule(weekday: 4, ordinals: [1, 3, 5]))!
        precondition(FlexStubProtocol.requests.isEmpty && rebuilt.accountIdentifier == result.accountIdentifier)
        precondition(rebuilt.customHolidayDeduction?.dates == ["2026-10-07", "2026-10-21"])
        precondition(rebuilt.month.targetMinutes == result.month.targetMinutes - 960)
        let cleared = try fetcher.rebuild(customHoliday: nil)
        precondition(cleared?.month.targetMinutes == result.month.targetMinutes && cleared?.customHolidayDeduction == nil)
        fetcher.restore([cookie()])
        let forgotten = try fetcher.rebuild(customHoliday: nil)
        precondition(forgotten == nil)
        FlexStubProtocol.requests = []
        let withHistory = try await client().snapshot(includePreviousPeriod: true)
        precondition(withHistory.month.actualMinutes == 4200 && withHistory.averageClockInMinute != nil)
        precondition(FlexStubProtocol.requests.count == 12)
    }
}
