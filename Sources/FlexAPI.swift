import Foundation


enum FlexError: LocalizedError {
    case authentication, permissionDenied, rateLimited, httpStatus(Int)
    case invalidData(String)
    var errorDescription: String? {
        switch self {
        case .authentication: "flex 로그인이 만료되었습니다. 다시 로그인해주세요."
        case .permissionDenied: "flex 근태 조회 권한을 확인해주세요."
        case .rateLimited: "flex 호출 한도에 도달했습니다. 잠시 후 다시 조회합니다."
        case .invalidData(let reason): "flex 근태 정보 확인 불가 · \(reason)"
        case .httpStatus(let status): "flex API 응답 오류 (\(status))"
        }
    }
}

private final class FlexRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // An API redirect is a login boundary; never forward session headers to it.
        completionHandler(nil)
    }
}

@MainActor
final class FlexClient {
    private let session: URLSession
    private let redirectDelegate = FlexRedirectDelegate()
    private let requestInterval: TimeInterval
    private var cookies: [HTTPCookie] = []
    private var revision = 0
    private var requestTask: Task<Data, Error>?
    private var nextRequestAt = Date.distantPast
    private var lastBuild: ((CustomHolidayRule?) throws -> AttendanceSnapshot)?

    init(configuration: URLSessionConfiguration = .ephemeral, requestInterval: TimeInterval = 1) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        self.requestInterval = requestInterval
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func restore(_ saved: [SavedCookie]) {
        revision += 1
        requestTask?.cancel()
        cookies = saved.filter { $0.belongsTo(.flex) && $0.isCurrent }.compactMap(\.cookie)
        lastBuild = nil
    }

    func currentCookies() -> [HTTPCookie] { cookies.filter { SavedCookie($0).isCurrent } }

    func clearCookies() { restore([]) }

    func cancelRequests() async {
        revision += 1
        requestTask?.cancel()
        for task in await session.allTasks { task.cancel() }
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: "https://flex.team")!
        guard path.hasPrefix("/api/v2/") || path.hasPrefix("/api/v3/") else { throw FlexError.invalidData("근태 조회 요청을 만들지 못했습니다.") }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        let url = components.url!
        let attempt = revision
        let previous = requestTask
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard self.revision == attempt else { throw CancellationError() }
            let request = URLRequest(url: url)
            do { return try await self.send(request, attempt: attempt) }
            catch FlexError.authentication {
                try await self.renewSession(attempt: attempt)
                return try await self.send(request, attempt: attempt)
            }
        }
        requestTask = task
        return try await task.value
    }

    private func send(_ original: URLRequest, attempt: Int) async throws -> Data {
        var request = original
        let url = request.url!
        let delay = nextRequestAt.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        guard revision == attempt else { throw CancellationError() }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ko", forHTTPHeaderField: "FlexTeam-Locale")
        request.setValue("base", forHTTPHeaderField: "x-flex-axios")
        request.setValue("FLEX", forHTTPHeaderField: "flexteam-productcode")
        request.setValue(AttendanceService.flex.webURL.absoluteString, forHTTPHeaderField: "Referer")
        let applicable = currentCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let hostMatches = domain.hasPrefix(".")
                ? url.host == String(domain.dropFirst()) || url.host!.hasSuffix(domain)
                : url.host == domain
            let pathMatches = url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            return hostMatches && pathMatches
        }
        guard !applicable.isEmpty else { throw FlexError.authentication }
        for (name, value) in HTTPCookie.requestHeaderFields(with: applicable) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        nextRequestAt = Date().addingTimeInterval(requestInterval)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard revision == attempt else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw FlexError.invalidData("서버 응답을 확인하지 못했습니다.") }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String, let value = item.value as? String { result[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) where SavedCookie(cookie).belongsTo(.flex) {
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if SavedCookie(cookie).isCurrent { cookies.append(cookie) }
        }
        switch response.statusCode {
        case 200..<300: break
        case 300..<400, 401: throw FlexError.authentication
        case 403: throw FlexError.permissionDenied
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            nextRequestAt = Date().addingTimeInterval(delay.isFinite ? min(86400, max(1, delay)) : 60)
            throw FlexError.rateLimited
        default: throw FlexError.httpStatus(response.statusCode)
        }
        guard response.mimeType == "application/json" else { throw FlexError.invalidData("서버가 근태 데이터 대신 다른 형식의 응답을 보냈습니다.") }
        return data
    }

    private func renewSession(attempt: Int) async throws {
        struct Customer: Decodable { let customerIdHash: String; let userIdHash: String }
        struct Token: Decodable { let token: String; let expireAt: String }
        struct Renewal: Decodable {
            struct Workspace: Decodable { let accessToken: Token; let refreshToken: Token? }
            let workspaceToken: Workspace
            let customerUserAccessToken: Token
        }
        let stored = currentCookies().filter { $0.domain == "flex.team" && $0.path == "/" }
        guard let refresh = stored.first(where: { $0.name == "V2_WS_RID" }),
              let info = stored.first(where: { $0.name == "V2_CUSTOMER_INFO" }),
              let data = info.value.removingPercentEncoding?.data(using: .utf8),
              let customer = try? JSONDecoder().decode(Customer.self, from: data),
              !customer.customerIdHash.isEmpty, !customer.userIdHash.isEmpty else { throw FlexError.authentication }
        var request = URLRequest(url: URL(string: "https://flex.team/api-public/v2/auth/tokens/customer-user/refresh")!)
        request.httpMethod = "POST"
        request.setValue(refresh.value, forHTTPHeaderField: "FlexTeam-V2-Workspace-Refresh")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["customerUuid": customer.customerIdHash, "userUuid": customer.userIdHash])
        let renewal = try JSONDecoder().decode(Renewal.self, from: await send(request, attempt: attempt))
        var tokens = [("V2_WS_AID", renewal.workspaceToken.accessToken), ("AID", renewal.customerUserAccessToken)]
        if let refresh = renewal.workspaceToken.refreshToken { tokens.append(("V2_WS_RID", refresh)) }
        tokens.append(("FlexTeam-Version", Token(token: "V2", expireAt:
            (renewal.workspaceToken.refreshToken ?? renewal.workspaceToken.accessToken).expireAt)))
        for (name, token) in tokens {
            let expires = try FlexDates.parse(token.expireAt)
            guard !token.token.isEmpty, expires > Date(), let cookie = HTTPCookie(properties: [
                .name: name, .value: token.token, .domain: "flex.team", .path: "/", .secure: "TRUE", .expires: expires
            ]) else { throw FlexError.invalidData("로그인 갱신 응답의 토큰 또는 유효기간을 확인하지 못했습니다.") }
            cookies.removeAll { $0.name == name && $0.domain == cookie.domain && $0.path == cookie.path }
            cookies.append(cookie)
        }
    }

    private func fetch<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await get(path, query: query))
    }

    func snapshot(includePreviousPeriod: Bool = false, customHoliday: CustomHolidayRule? = nil) async throws -> AttendanceSnapshot {
        let attempt = revision
        func load<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
            guard revision == attempt else { throw CancellationError() }
            let value: T = try await fetch(path, query: query)
            guard revision == attempt else { throw CancellationError() }
            return value
        }
        let identity: FlexIdentity = try await load("/api/v2/workspace/users/me/workspace-users")
        let user = identity.currentUser.user
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard [user.userIdHash, user.customerIdHash].allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw FlexError.invalidData("계정의 회사 또는 사용자 식별 정보를 확인하지 못했습니다.")
        }
        let ruleBase = "/api/v2/work-rule/users/\(user.userIdHash)"
        let scheduleBase = "/api/v3/time-tracking/users/\(user.userIdHash)/work-schedules"
        let serverTime: FlexServerTime = try await load("/api/v2/time-tracking/current-time")
        let serverClockOffset = ServerClock(serverTime: try FlexDates.timestamp(serverTime.timeStamp), deviceTime: Date()).offset
        let status: FlexClockStatus = try await load("/api/v2/time-tracking/work-clock/users/\(user.userIdHash)/current-status")
        guard let zone = TimeZone(identifier: status.appliedZoneId) else { throw FlexError.invalidData("적용된 근무 시간대를 확인하지 못했습니다.") }
        let workDate = status.onGoingRecordPack?.onGoing == true
            ? FlexDates.key(try FlexDates.timestamp(status.onGoingRecordPack!.startRecord.targetTime), in: zone)
            : status.targetDate
        var period: FlexPeriodResponse = try await load(ruleBase + "/working-periods/now")
        if workDate < period.period.from || workDate > period.period.to {
            period = try await load(ruleBase + "/working-periods/by-date", query: [
                URLQueryItem(name: "date", value: workDate), URLQueryItem(name: "timezone", value: zone.identifier)])
        }
        let summary: FlexPeriodSummary = try await load(scheduleBase + "/summary/by-working-period", query: [
            URLQueryItem(name: "timestamp", value: String(period.period.applyTimeRangeFrom)),
            URLQueryItem(name: "timezone", value: period.period.zoneId)])
        func query(_ from: String, _ to: String) -> [URLQueryItem] {
            [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to),
             URLQueryItem(name: "timezone", value: period.period.zoneId)]
        }
        guard summary.userIdHash == user.userIdHash else { throw FlexError.invalidData("월간 집계의 사용자와 로그인 계정이 다릅니다.") }
        let today: FlexDailySummary = try await load(scheduleBase + "/summary/by-date-range", query: query(workDate, workDate))
        let start = try FlexDates.day(period.period.from, in: zone)
        let end = try FlexDates.day(period.period.to, in: zone)
        guard end >= start, end.timeIntervalSince(start) <= 366 * 86400,
              try FlexDates.timestamp(Double(period.period.applyTimeRangeFrom)) == start,
              try FlexDates.timestamp(Double(period.period.applyTimeRangeTo)) == FlexDates.calendar(in: zone).date(byAdding: .day, value: 1, to: end) else {
            throw FlexError.invalidData("정산 기간의 날짜와 시작·종료 시각이 맞지 않습니다.")
        }
        let historyStart = includePreviousPeriod ? FlexDates.calendar(in: zone).date(byAdding: .month, value: -1, to: start)! : start
        var schedules: [FlexSchedule] = [], attributes: [FlexDayAttribute] = []
        for (from, to) in FlexDates.ranges(from: historyStart, through: end, in: zone) {
            let days: FlexSchedules = try await load(scheduleBase, query: query(from, to))
            let dates: FlexDayAttributes = try await load(scheduleBase + "/date-attributes", query: query(from, to))
            guard days.userIdHash == user.userIdHash else { throw FlexError.invalidData("근무 일정의 사용자와 로그인 계정이 다릅니다.") }
            schedules += days.dailySchedules
            attributes += dates.workingDayAttributes
        }
        let rule: FlexUserRule = try await load(ruleBase + "/work-rules/by-date/" + workDate)
        guard !rule.workRule.customerWorkRuleId.isEmpty,
              rule.workRule.customerWorkRuleId.allSatisfy(\.isNumber) else { throw FlexError.invalidData("적용된 근무 규칙의 식별 정보를 확인하지 못했습니다.") }
        let rules: FlexRules = try await load("/api/v2/work-rule/customers/\(user.customerIdHash)/work-rules/\(rule.workRule.customerWorkRuleId)")
        guard let companyRule = rules.workRules.first(where: { $0.customerWorkRuleId == rule.workRule.customerWorkRuleId }),
              revision == attempt else { throw FlexError.invalidData("적용된 회사 근무 규칙을 찾지 못했습니다.") }
        let account = user.customerIdHash + ":" + user.userIdHash
        let build = { (holiday: CustomHolidayRule?) throws -> AttendanceSnapshot in
            var result = try FlexAttendance.snapshot(period: period.period, summary: summary, today: today,
                status: status, schedules: schedules, attributes: attributes, rule: companyRule,
                customHoliday: holiday, serverClockOffset: serverClockOffset)
            result.accountIdentifier = account
            return result
        }
        let result = try build(customHoliday)
        lastBuild = build
        return result
    }

    /// Recomputes the last fetched snapshot for another custom holiday without a request; nil before any fetch.
    func rebuild(customHoliday: CustomHolidayRule?) throws -> AttendanceSnapshot? {
        try lastBuild?(customHoliday)
    }
}
