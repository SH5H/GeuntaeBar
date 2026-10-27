import AppKit
import Network
import ServiceManagement
import SwiftUI
import UserNotifications
import WebKit

final class ClockInNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "geuntae-bar-notification-test" {
            completionHandler()
            return
        }
        DispatchQueue.main.async {
            let service = AttendanceService(rawValue: response.notification.request.content.userInfo["service"] as? String ?? "") ?? .wantedSpace
            NSWorkspace.shared.open(service.webURL)
        }
        completionHandler()
    }
}

@MainActor
final class SessionEpoch {
    private var generation = 0
    private var activeFetches = 0
    private var quiesceWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> Int {
        activeFetches += 1
        return generation
    }

    func isCurrent(_ revision: Int) -> Bool { revision == generation }

    func invalidate() { generation += 1 }

    func finish() {
        activeFetches -= 1
        guard activeFetches == 0 else { return }
        let waiters = quiesceWaiters
        quiesceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func quiesce() async {
        guard activeFetches > 0 else { return }
        await withCheckedContinuation { quiesceWaiters.append($0) }
    }
}

final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var remindersEnabled: Bool {
        get { defaults.object(forKey: "clockInRemindersEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clockInRemindersEnabled") }
    }
    var reminderMode: ClockInReminderMode {
        get { ClockInReminderMode(rawValue: defaults.string(forKey: "clockInReminderMode") ?? "") ?? .scheduled }
        set { defaults.set(newValue.rawValue, forKey: "clockInReminderMode") }
    }
    var reminderDelayMinutes: Int {
        get { defaults.integer(forKey: "clockInReminderDelayMinutes") }
        set { defaults.set(newValue, forKey: "clockInReminderDelayMinutes") }
    }
    func leaveByDate(for snapshot: AttendanceSnapshot) -> [String: LeaveOptions] {
        let key = "calendarLeave-\(snapshot.service.rawValue)-\(snapshot.accountIdentifier)"
        var leaves: [String: LeaveOptions] = [:]
        if let data = defaults.data(forKey: key) {
            if let saved = try? JSONDecoder().decode([String: LeaveOptions].self, from: data) {
                leaves = saved
            } else if let legacy = try? JSONDecoder().decode([String: LegacyLeave].self, from: data) {
                leaves = legacy.mapValues {
                    LeaveOptions(recognizesScheduledWork: true, recognizesOvertime: $0 == .paid)
                }
                setLeaveByDate(leaves, for: snapshot)
            }
        }
        if snapshot.service == .flex,
           let data = defaults.data(forKey: "customHolidayRule"),
           let legacy = try? JSONDecoder().decode(LegacyHoliday.self, from: data) {
            let month = AttendanceCalendarMonth(snapshot: snapshot)
            for record in snapshot.calendarRecords where record.isScheduledWorkday &&
                record.date >= snapshot.month.startDate && record.date <= snapshot.month.endDate {
                guard let date = month.formatter.date(from: record.date),
                      month.calendar.component(.weekday, from: date) == legacy.weekday,
                      legacy.ordinals.contains((month.calendar.component(.day, from: date) - 1) / 7 + 1),
                      leaves[record.date] == nil else { continue }
                leaves[record.date] = LeaveOptions(recognizesScheduledWork: true,
                                                  recognizesOvertime: legacy.affectsCompensation != false)
            }
            setLeaveByDate(leaves, for: snapshot)
            defaults.removeObject(forKey: "customHolidayRule")
        }
        return leaves
    }

    func setLeaveByDate(_ leaves: [String: LeaveOptions], for snapshot: AttendanceSnapshot) {
        defaults.set(try? JSONEncoder().encode(leaves),
                     forKey: "calendarLeave-\(snapshot.service.rawValue)-\(snapshot.accountIdentifier)")
    }

    private enum LegacyLeave: String, Decodable {
        case paid
        case unpaid
    }

    private struct LegacyHoliday: Decodable {
        let weekday: Int
        let ordinals: Set<Int>
        let affectsCompensation: Bool?
    }
    var attendanceService: AttendanceService? {
        get { AttendanceService(rawValue: defaults.string(forKey: "attendanceService") ?? "") }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: "attendanceService") }
            else { defaults.removeObject(forKey: "attendanceService") }
        }
    }
    func reminderDayKey(account: String) -> String { "lastClockInReminderDate-\(account)" }
    func lastRemindedDay(for account: String) -> String? {
        defaults.string(forKey: reminderDayKey(account: account))
    }
    func setLastRemindedDay(_ day: String, for account: String) {
        defaults.set(day, forKey: reminderDayKey(account: account))
    }
}
enum RefreshFailure {
    case signedOut(loginMessage: String, status: String)
    case failed(loginMessage: String, status: String)

    static let signInRequired = RefreshFailure.signedOut(
        loginMessage: "로그인 정보를 확인하지 못했어요. 다시 로그인해주세요.", status: "로그인이 필요합니다")
    static func failed(_ error: Error, connectionMessage: String) -> RefreshFailure {
        .failed(loginMessage: error is KeychainError
                    ? "로그인 정보를 저장하지 못했어요. macOS 키체인 접근을 확인하고 다시 시도해주세요."
                    : connectionMessage,
                status: "업데이트 실패: \(error.localizedDescription)")
    }
}

/// One attendance backend: its saved session, network client, and web-login cookies.
@MainActor
protocol AttendanceBackend: AnyObject {
    var currentCookies: [HTTPCookie] { get }
    var webDataStore: WKWebsiteDataStore { get }
    /// Restores the saved session into the client; returns whether one exists.
    func restoreSession() throws -> Bool
    /// Adopts cookies from the web login; returns false when none belong to this backend.
    func adoptCookies(_ cookies: [HTTPCookie]) -> Bool
    func loadSnapshot(includePreviousPeriod: Bool) async throws -> AttendanceSnapshot
    /// Persists the session after a successful load; returns false when `isCurrent` turned false midway.
    func saveSession(isCurrent: () -> Bool) async throws -> Bool
    /// Maps a failed load to what the user sees, forgetting credentials the server rejected.
    func failure(for error: Error, hadSession: Bool) -> RefreshFailure
    func signOut() async throws
    func cancelRequests() async
}

@MainActor
final class WantedSpaceBackend: AttendanceBackend {
    private let vault: KeychainSession
    private let client: AttendanceClient
    let webDataStore: WKWebsiteDataStore
    private var webCookieStore: WKHTTPCookieStore { webDataStore.httpCookieStore }
    private let snapshotLoader: (Bool) async throws -> AttendanceSnapshot
    private let sessionSaver: ([HTTPCookie]) throws -> Void

    init(vault: KeychainSession = KeychainSession(legacyService: "ai.wantedspace.WorkBar.v2"),
         client: AttendanceClient = AttendanceClient(),
         webDataStore: WKWebsiteDataStore? = nil,
         snapshotLoader: ((Bool) async throws -> AttendanceSnapshot)? = nil,
         sessionSaver: (([HTTPCookie]) throws -> Void)? = nil) {
        self.vault = vault
        self.client = client
        self.webDataStore = webDataStore ?? .default()
        self.snapshotLoader = snapshotLoader ?? { try await client.snapshot(includePreviousMonth: $0) }
        self.sessionSaver = sessionSaver ?? { _ = try vault.save($0) }
    }

    var currentCookies: [HTTPCookie] { client.currentCookies() }
    func restoreSession() throws -> Bool {
        let cookies = try vault.load()
        client.restore(cookies)
        return !cookies.isEmpty
    }
    func adoptCookies(_ cookies: [HTTPCookie]) -> Bool {
        guard cookies.contains(where: { SavedCookie($0).belongsTo(.wantedSpace) && SavedCookie($0).isCurrent }) else { return false }
        client.restore(cookies.map(SavedCookie.init))
        return true
    }
    func loadSnapshot(includePreviousPeriod: Bool) async throws -> AttendanceSnapshot {
        try await snapshotLoader(includePreviousPeriod)
    }
    func saveSession(isCurrent: () -> Bool) async throws -> Bool {
        try sessionSaver(currentCookies)
        return true
    }
    func failure(for error: Error, hadSession: Bool) -> RefreshFailure {
        if case AttendanceError.signInRequired = error {
            try? vault.delete()
            return .signInRequired
        }
        return .failed(error, connectionMessage: "근태 정보를 연결하지 못했어요. 연결을 확인하고 다시 시도해주세요.")
    }
    func signOut() async throws {
        try vault.delete()
        client.clearCookies()
        for cookie in await webCookieStore.allCookies() where SavedCookie(cookie).belongsTo(.wantedSpace) {
            await webCookieStore.deleteCookie(cookie)
        }
    }
    func cancelRequests() async { await client.cancelRequests() }
}

@MainActor
final class FlexBackend: AttendanceBackend {
    private let vault: KeychainSession
    private let client: FlexClient
    private(set) var webDataStore: WKWebsiteDataStore
    private var webCookieStore: WKHTTPCookieStore { webDataStore.httpCookieStore }
    private let snapshotLoader: (Bool) async throws -> AttendanceSnapshot
    private let sessionSaver: ([HTTPCookie]) throws -> Void

    init(vault: KeychainSession = KeychainSession(service: "ai.wantedspace.WorkBar.flex.web",
             attendanceService: .flex, legacyItemsToPurge: [
                 KeychainSession.Item(service: "ai.wantedspace.WorkBar.flex", account: "flex-credentials")
             ]),
         client: FlexClient? = nil,
         webDataStore: WKWebsiteDataStore? = nil,
         snapshotLoader: ((Bool) async throws -> AttendanceSnapshot)? = nil,
         sessionSaver: (([HTTPCookie]) throws -> Void)? = nil) {
        self.vault = vault
        let client = client ?? FlexClient()
        self.client = client
        self.webDataStore = webDataStore ?? .nonPersistent()
        self.snapshotLoader = snapshotLoader ?? { try await client.snapshot(includePreviousPeriod: $0) }
        self.sessionSaver = sessionSaver ?? { _ = try vault.save($0) }
    }

    var currentCookies: [HTTPCookie] { client.currentCookies() }
    func restoreSession() throws -> Bool {
        let cookies = try vault.load()
        client.restore(cookies)
        return !cookies.isEmpty
    }
    func adoptCookies(_ cookies: [HTTPCookie]) -> Bool {
        guard cookies.contains(where: { SavedCookie($0).belongsTo(.flex) && SavedCookie($0).isCurrent }) else { return false }
        client.restore(cookies.map(SavedCookie.init))
        return true
    }
    func loadSnapshot(includePreviousPeriod: Bool) async throws -> AttendanceSnapshot {
        try await snapshotLoader(includePreviousPeriod)
    }
    func saveSession(isCurrent: () -> Bool) async throws -> Bool {
        try sessionSaver(currentCookies)
        // Mirror renewed cookies so the login web view stays signed in.
        for cookie in currentCookies {
            guard isCurrent() else { return false }
            await webCookieStore.setCookie(cookie)
        }
        guard isCurrent() else { return false }
        // Best-effort: a stale legacy item must not fail a successful refresh.
        try? vault.purgeLegacyItems()
        return true
    }
    func failure(for error: Error, hadSession: Bool) -> RefreshFailure {
        switch error {
        case FlexError.authentication:
            client.clearCookies()
            try? vault.delete()
            return .signedOut(loginMessage: FlexError.authentication.localizedDescription, status: "flex 재연결이 필요합니다")
        case AttendanceError.signInRequired:
            try? vault.delete()
            return .signInRequired
        default:
            if !(error is KeychainError) && (hadSession || !currentCookies.isEmpty) {
                // Keep cookies renewed by partial requests.
                do { try sessionSaver(currentCookies) }
                catch { return .failed(loginMessage: error.localizedDescription, status: "Keychain 저장 실패") }
            }
            return .failed(error, connectionMessage: error.localizedDescription)
        }
    }
    func signOut() async throws {
        client.clearCookies()
        let signedInStore = webDataStore
        webDataStore = .nonPersistent()
        for cookie in await signedInStore.httpCookieStore.allCookies() where SavedCookie(cookie).belongsTo(.flex) {
            await signedInStore.httpCookieStore.deleteCookie(cookie)
        }
        try vault.delete()
    }
    func cancelRequests() async { await client.cancelRequests() }
}

@MainActor
final class WorkBarModel: ObservableObject {
    @Published private(set) var snapshot: AttendanceSnapshot?
    @Published private(set) var message = "로그인이 필요합니다"
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var hasSavedSession = false
    @Published private(set) var loginCompleted = false
    @Published private(set) var loginFailureMessage: String?
    @Published private(set) var selectedService: AttendanceService
    @Published var remindersEnabled: Bool {
        didSet {
            preferences.remindersEnabled = remindersEnabled
            if remindersEnabled {
                if servicesStarted { registerLoginItem() }
                Task { await prepareNotifications() }
                Task { await refresh() }
            } else {
                reminderTimer?.invalidate()
                try? SMAppService.mainApp.unregister()
            }
        }
    }
    @Published var reminderMode: ClockInReminderMode {
        didSet {
            preferences.reminderMode = reminderMode
            Task { await refresh() }
            if let snapshot { scheduleReminderCheck(snapshot) }
        }
    }
    @Published var reminderDelayMinutes: Int {
        didSet {
            preferences.reminderDelayMinutes = reminderDelayMinutes
            if let snapshot { scheduleReminderCheck(snapshot) }
        }
    }
    @Published private(set) var reminderMessage: String?
    @Published private(set) var isTestingNotification = false

    private let wantedSpace: AttendanceBackend
    private let flex: AttendanceBackend
    var loginWebDataStore: WKWebsiteDataStore { backend.webDataStore }
    private let preferences: Preferences
    private var fetchedSnapshot: AttendanceSnapshot?
    private let notificationAuthorizationStatus: () async -> UNAuthorizationStatus
    private let requestNotificationAuthorization: () async throws -> Bool
    private let sendNotification: (UNNotificationRequest) async throws -> Void
    private let notificationDelegate = ClockInNotificationDelegate()
    private var timer: Timer?
    private var liveTimer: Timer?
    private var reminderTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var servicesStarted = false
    private var networkAvailable = true
    private let sessionEpoch = SessionEpoch()
    private var signedOutByUser = false

    init(wantedSpace: AttendanceBackend? = nil,
         flex: AttendanceBackend? = nil,
         defaults: UserDefaults = .standard,
         service: AttendanceService? = nil,
         notificationAuthorizationStatus: @escaping () async -> UNAuthorizationStatus = {
             await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
         },
         requestNotificationAuthorization: @escaping () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
         },
         sendNotification: @escaping (UNNotificationRequest) async throws -> Void = {
             try await UNUserNotificationCenter.current().add($0)
         }) {
        let preferences = Preferences(defaults: defaults)
        self.wantedSpace = wantedSpace ?? WantedSpaceBackend()
        self.flex = flex ?? FlexBackend()
        self.preferences = preferences
        self.notificationAuthorizationStatus = notificationAuthorizationStatus
        self.requestNotificationAuthorization = requestNotificationAuthorization
        self.sendNotification = sendNotification
        self.selectedService = service ?? preferences.attendanceService ?? .wantedSpace
        self.remindersEnabled = preferences.remindersEnabled
        self.reminderMode = preferences.reminderMode
        self.reminderDelayMinutes = preferences.reminderDelayMinutes
        restoreSelectedSession()
    }

    func start() {
        guard !servicesStarted else { return }
        servicesStarted = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        if remindersEnabled { registerLoginItem() }
        if hasSavedSession { Task { await refresh() } }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let liveTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceLiveTime() }
        }
        RunLoop.main.add(liveTimer, forMode: .common)
        self.liveTimer = liveTimer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in await self?.networkChanged(path.status == .satisfied) }
        }
        pathMonitor.start(queue: .main)
        self.pathMonitor = pathMonitor
    }

    func networkChanged(_ available: Bool) async {
        let wasAvailable = networkAvailable
        networkAvailable = available
        if available && !wasAvailable && hasSavedSession { await refresh() }
    }

    var menuTitle: String { snapshot?.menuTitle ?? "근태 --" }

    func advanceLiveTime(to date: Date = Date()) {
        guard selectedService == .flex, loginCompleted, !isSigningOut,
              var fresh = snapshot, fresh.service == .flex, fresh.liveWorkClock != nil,
              ServerClock(offset: fresh.serverClockOffset, updatedAt: fresh.updatedAt).isFresh(at: date) else { return }
        fresh.advanceLiveTime(to: date)
        if fresh.todayMinutes != snapshot?.todayMinutes || fresh.attendanceNote != snapshot?.attendanceNote {
            fetchedSnapshot?.advanceLiveTime(to: date)
            snapshot = fresh
        }
    }

    func setLeave(_ options: LeaveOptions?, on date: String) {
        guard loginCompleted, !isSigningOut, let raw = fetchedSnapshot,
              raw.service == selectedService,
              date >= raw.month.startDate, date <= raw.month.endDate,
              raw.calendarRecords.contains(where: { $0.date == date }) else { return }
        var leaves = preferences.leaveByDate(for: raw)
        leaves[date] = options
        preferences.setLeaveByDate(leaves, for: raw)
        snapshot = raw.applyingLeave(leaves)
        advanceLiveTime()
        if let snapshot { scheduleReminderCheck(snapshot) }
    }

    private var backend: AttendanceBackend { selectedService == .flex ? flex : wantedSpace }

    private func restoreSelectedSession() {
        do {
            hasSavedSession = try backend.restoreSession()
            message = hasSavedSession ? "근태 확인 중…" : "로그인이 필요합니다"
        } catch {
            message = "Keychain을 읽을 수 없습니다"
            loginFailureMessage = "저장된 로그인 정보를 읽지 못했어요. macOS 키체인 접근을 확인해주세요."
        }
    }

    func selectService(_ service: AttendanceService) async {
        guard service != selectedService, !isSigningOut else { return }
        isSigningOut = true
        signedOutByUser = true
        await quiesceSession()
        selectedService = service

        preferences.attendanceService = service
        hasSavedSession = false
        restoreSelectedSession()
        signedOutByUser = false
        isSigningOut = false
        if hasSavedSession { await refresh() }
    }
    private func quiesceSession() async {
        sessionEpoch.invalidate()
        isRefreshing = false
        snapshot = nil
        fetchedSnapshot = nil
        loginCompleted = false
        loginFailureMessage = nil
        reminderTimer?.invalidate()
        await backend.cancelRequests()
        await sessionEpoch.quiesce()
    }

    var loginCookies: [HTTPCookie] { backend.currentCookies }

    func beginSignIn() {
        guard !isSigningOut else { return }
        signedOutByUser = false
        sessionEpoch.invalidate()
        loginCompleted = false
        loginFailureMessage = nil
        message = "로그인이 필요합니다"
    }

    func acceptCookies(_ cookies: [HTTPCookie]) async {
        guard !isRefreshing, !isSigningOut, !signedOutByUser, backend.adoptCookies(cookies) else { return }
        loginCompleted = false
        loginFailureMessage = nil
        await refresh()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isRefreshing, !isSigningOut, !signedOutByUser else { return false }
        guard networkAvailable else {
            message = "네트워크 연결을 기다리는 중"
            return false
        }
        let revision = sessionEpoch.begin()
        isRefreshing = true
        reminderTimer?.invalidate()
        defer {
            sessionEpoch.finish()
            isRefreshing = false
        }
        do {
            let raw = try await backend.loadSnapshot(includePreviousPeriod: remindersEnabled && reminderMode == .average)
            guard sessionEpoch.isCurrent(revision),
                  try await backend.saveSession(isCurrent: { sessionEpoch.isCurrent(revision) }) else { return false }
            fetchedSnapshot = raw
            let fresh = raw.applyingLeave(preferences.leaveByDate(for: raw))
            snapshot = fresh
            hasSavedSession = true
            loginCompleted = true
            loginFailureMessage = nil
            message = "방금 업데이트됨"
            if remindersEnabled {
                scheduleReminderCheck(fresh)
                await prepareNotifications()
                guard sessionEpoch.isCurrent(revision), !isSigningOut else { return false }
                await remindIfNeeded(fresh, revision: revision)
            }
            return sessionEpoch.isCurrent(revision) && loginCompleted
        } catch {
            guard sessionEpoch.isCurrent(revision) else { return false }
            loginCompleted = false
            switch backend.failure(for: error, hadSession: hasSavedSession) {
            case let .signedOut(loginMessage, status):
                snapshot = nil
                fetchedSnapshot = nil
                hasSavedSession = false
                loginFailureMessage = loginMessage
                message = status
            case let .failed(loginMessage, status):
                loginFailureMessage = loginMessage
                message = status
            }
        }
        return false
    }


    private func registerLoginItem() {
        if SMAppService.mainApp.status == .requiresApproval {
            reminderMessage = "macOS 로그인 항목에서 Geuntae bar를 허용해주세요"
            return
        }
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                reminderMessage = "macOS 로그인 항목에서 Geuntae bar를 허용해주세요"
            }
        } catch {
            reminderMessage = "로그인 시 자동 실행 설정 실패: \(error.localizedDescription)"
        }
    }

    private func scheduleReminderCheck(_ fresh: AttendanceSnapshot) {
        reminderTimer?.invalidate()
        guard remindersEnabled,
              let due = fresh.clockInReminderDate(mode: reminderMode,
                                                  delayMinutes: reminderDelayMinutes),
              due > Date() else { return }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    @discardableResult
    private func prepareNotifications() async -> Bool {
        let status = await notificationAuthorizationStatus()
        let allowed: Bool
        do {
            allowed = status == .notDetermined ? try await requestNotificationAuthorization() : status == .authorized
        } catch {
            reminderMessage = "알림 권한 요청 실패: \(error.localizedDescription)"
            return false
        }
        if !allowed {
            reminderMessage = "macOS 알림 설정에서 Geuntae bar 알림을 허용해주세요"
        } else if reminderMessage?.hasPrefix("macOS 알림 설정") == true {
            reminderMessage = nil
        }
        return allowed
    }

    func testNotification() async {
        guard !isTestingNotification else { return }
        isTestingNotification = true
        defer { isTestingNotification = false }
        reminderMessage = "알림 권한 확인 중…"
        guard await prepareNotifications() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Geuntae bar 알림 테스트"
        content.body = "이 알림이 보이면 알림 표시가 정상적으로 동작하고 있습니다."
        content.sound = .default
        do {
            try await sendNotification(UNNotificationRequest(identifier: "geuntae-bar-notification-test",
                                                             content: content, trigger: nil))
            reminderMessage = "테스트 알림을 보냈어요. 보이지 않으면 macOS 알림 설정과 집중 모드를 확인해주세요."
        } catch {
            reminderMessage = "테스트 알림 전송 실패: \(error.localizedDescription)"
        }
    }

    private func remindIfNeeded(_ fresh: AttendanceSnapshot, revision: Int) async {
        let account = "\(selectedService.rawValue)-\(fresh.accountIdentifier)"
        let lastRemindedDay = preferences.lastRemindedDay(for: account)
        guard hasSavedSession, remindersEnabled,
              let plan = ClockInReminderPlanner.plan(snapshot: fresh, now: Date(), mode: reminderMode,
                  delayMinutes: reminderDelayMinutes, lastRemindedDay: lastRemindedDay,
                  account: account) else { return }
        let status = await notificationAuthorizationStatus()
        guard sessionEpoch.isCurrent(revision), !isSigningOut,
              status == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.userInfo = ["service": selectedService.rawValue]
        content.sound = .default
        do {
            try await sendNotification(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil))
            preferences.setLastRemindedDay(plan.day, for: account)
        } catch {
            reminderMessage = "출근 알림 전송 실패: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        signedOutByUser = true
        await quiesceSession()
        message = "로그아웃 중…"
        do { try await backend.signOut() }
        catch {
            message = "Keychain 삭제 실패"
            loginFailureMessage = "저장된 로그인 정보를 삭제하지 못했어요. macOS 키체인 접근을 확인하고 다시 로그아웃해주세요."
            return
        }
        hasSavedSession = false
        message = "로그인이 필요합니다"
    }
}

struct LoginWebView: NSViewRepresentable {
    enum LoadState: Equatable {
        case loading, ready, failed(String)
    }

    @ObservedObject var model: WorkBarModel
    @Binding var loadState: LoadState

    init(model: WorkBarModel, loadState: Binding<LoadState> = .constant(.loading)) {
        self.model = model
        self._loadState = loadState
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model) { loadState = $0 }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = model.loginWebDataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.watch(webView)
        let service = model.selectedService
        let cookies = model.loginCookies
        Task { @MainActor in
            for cookie in cookies {
                guard context.coordinator.isActive, model.selectedService == service else { return }
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            guard context.coordinator.isActive, model.selectedService == service else { return }
            webView.load(URLRequest(url: service.webURL))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: WorkBarModel
        private let onLoadStateChange: (LoadState) -> Void
        private var loadState = LoadState.loading {
            didSet { onLoadStateChange(loadState) }
        }
        private var timer: Timer?
        private var lastAttemptedCookies: Set<SavedCookie> = []
        private let service: AttendanceService
        private let webDataStore: WKWebsiteDataStore
        var isActive: Bool {
            timer != nil && model.selectedService == service && model.loginWebDataStore === webDataStore
        }

        init(model: WorkBarModel, onLoadStateChange: @escaping (LoadState) -> Void) {
            self.model = model
            self.service = model.selectedService
            self.webDataStore = model.loginWebDataStore
            self.onLoadStateChange = onLoadStateChange
        }

        func watch(_ webView: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.checkLogin(webView)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loadState = .loading
            lastAttemptedCookies.removeAll()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadState = .ready
            checkLogin(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(error)
        }

        private func navigationFailed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            loadState = .failed("로그인 화면을 불러오지 못했어요. 연결을 확인하고 다시 시도해주세요.")
        }

        private func checkLogin(_ webView: WKWebView) {
            guard isActive, loadState == .ready,
                  !model.loginCompleted, !model.isRefreshing, !model.isSigningOut,
                  model.selectedService == service, let url = webView.url else { return }
            let ready = service == .flex
                ? url.host == "flex.team" && (url.path == "/home" || url.path.hasPrefix("/time-tracking/"))
                : url.host == "dashboard.handyspace.ai" && (url.path == "/main" ||
                    (url.path.hasPrefix("/work/") && webView.title?.contains("근무/휴가") == true))
            guard ready else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, self.isActive else { return }
                Task { @MainActor in
                    guard self.isActive, !self.model.loginCompleted,
                          self.model.selectedService == self.service,
                          !self.model.isRefreshing, !self.model.isSigningOut else { return }
                    let current = Set(cookies.map(SavedCookie.init).filter { $0.belongsTo(self.service) && $0.isCurrent })
                    guard !current.isEmpty, current != self.lastAttemptedCookies else { return }
                    self.lastAttemptedCookies = current
                    await self.model.acceptCookies(cookies)
                }
            }
        }
    }
}

struct LoginWindow: View {
    @ObservedObject var model: WorkBarModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var loadState = LoginWebView.LoadState.loading
    @State private var loginAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            AttendanceServicePicker(model: model).padding()
            Group {
                LoginWebView(model: model, loadState: $loadState)
                    .id("\(model.selectedService.rawValue)-\(loginAttempt)")
                    .id(ObjectIdentifier(model.loginWebDataStore))
                HStack {
                    if case .failed(let message) = loadState {
                        Text(message)
                    } else {
                        Text(model.isRefreshing ? "근태 정보를 확인하고 연결하는 중…"
                             : loadState == .loading ? "로그인 화면을 불러오는 중…"
                             : model.loginFailureMessage ?? "\(model.selectedService.name) 계정으로 로그인해주세요.")
                    }
                    Spacer()
                    Button("다시 시도") {
                        model.beginSignIn()
                        loadState = .loading
                        loginAttempt += 1
                    }
                    .disabled(model.isRefreshing)
                }
                .font(.caption)
                .padding(8)
            }
        }
            .onChange(of: model.loginCompleted) { _, completed in
                if completed { dismissWindow(id: "signIn") }
            }
    }
}

@MainActor
final class WorkBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidUpdate(_ notification: Notification) {
        let app = NSApplication.shared
        let hasWindow = app.windows.contains {
            $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if app.activationPolicy() != policy { app.setActivationPolicy(policy) }
    }
}

#if !WORKBAR_TESTS
@main
struct GeuntaeBarApp: App {
    @NSApplicationDelegateAdaptor(WorkBarAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkBarModel()
    @StateObject private var onboarding = OnboardingState()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            WorkMenu(model: model)
        } label: {
            LaunchLabel(model: model, onboarding: onboarding)
                .task {
                    model.start()
                    updater.start()
                    if updater.automaticChecks { await updater.check() }
                }
        }
        .menuBarExtraStyle(.window)
        Window("Geuntae bar 옵션", id: "options") {
            WorkOptionsWindow(model: model, onboarding: onboarding, updater: updater)
        }
        .defaultSize(width: 420, height: 580)
        .windowResizability(.contentSize)
        Window("Geuntae bar 사용 가이드", id: "onboarding") {
            OnboardingWindow(model: model, onboarding: onboarding)
        }
        .defaultSize(width: min(920, NSScreen.main?.visibleFrame.width ?? 920),
                     height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 40))
        .windowResizability(.contentMinSize)
        Window("근태 서비스 연결", id: "signIn") {
            LoginWindow(model: model)
        }
        .defaultSize(width: 1000, height: 760)
    }
}
#endif

struct LaunchLabel: View {
    @ObservedObject var model: WorkBarModel
    @ObservedObject var onboarding: OnboardingState
    @Environment(\.openWindow) private var openWindow
    @State private var rightClickMonitor: Any?

    var body: some View {
        Image(nsImage: Self.progressImage(snapshot: model.snapshot))
            .renderingMode(.original)
            .help(progressDescription)
            .accessibilityLabel("\(model.snapshot?.dayTitle ?? "오늘") 누적 근무시간 · 한 칸 1시간, 한 바퀴 8시간")
            .accessibilityValue(progressDescription)
            .onAppear {
                if rightClickMonitor == nil {
                    rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown,
                                                                         handler: Self.forwardRightClick)
                }
                if let destination = onboarding.launch(hasSavedSession: model.hasSavedSession) {
                    openWindow(id: destination.rawValue)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            .onDisappear {
                if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
                rightClickMonitor = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: AppUpdater.showProgressNotification)) { _ in
                openWindow(id: "options")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .onChange(of: model.hasSavedSession) { _, saved in
                guard !model.isSigningOut else { return }
                if let destination = onboarding.sessionChanged(hasSavedSession: saved) {
                    openWindow(id: destination.rawValue)
                }
            }
    }

    private var progressDescription: String {
        guard let snapshot = model.snapshot else { return model.message }
        guard snapshot.attendanceKnown else { return snapshot.attendanceDescription }
        guard snapshot.record?.start?.isEmpty == false else { return snapshot.menuTitle }
        guard let meter = snapshot.minimumTodayMeter else {
            let dailyTarget = snapshot.dailyTargetMinutes.flatMap { $0 > 0 ? $0 : nil } ?? snapshot.month.dailyRequiredMinutes
            let reason = snapshot.record.flatMap { snapshot.leaveByDate[$0.date]?.title } ?? "최소 목표 없음"
            return "\(snapshot.menuTitle) · \(reason) · 일일 기준 \(AttendanceSnapshot.duration(dailyTarget))"
        }
        let state = snapshot.record?.end?.isEmpty == false ? "퇴근 완료 · " : ""
        let extra = snapshot.minimumTodayOvertimeMinutes > 0
            ? " · 최소 목표 초과 \(AttendanceSnapshot.duration(snapshot.minimumTodayOvertimeMinutes))" : ""
        if meter.targetMinutes == 0 {
            return "\(state)\(snapshot.monthTitle) 필수 근무시간 달성 · 일일 기준 \(AttendanceSnapshot.duration(snapshot.dailyTargetMinutes.flatMap { $0 > 0 ? $0 : nil } ?? snapshot.month.dailyRequiredMinutes))\(extra)"
        }
        return "\(state)\(snapshot.dayTitle) \(AttendanceSnapshot.duration(meter.actualMinutes)) / 최소 \(AttendanceSnapshot.duration(meter.targetMinutes)) · \(meter.percent)%\(extra)"
    }

    static func progressImage(snapshot: AttendanceSnapshot?) -> NSImage {
        let attendanceKnown = snapshot?.attendanceKnown == true
        let started = attendanceKnown && snapshot?.record?.start?.isEmpty == false
        let finished = started && snapshot?.record?.end?.isEmpty == false
        let waiting = attendanceKnown && snapshot?.record != nil && !started
        let actual = started ? max(0, snapshot?.todayMinutes ?? 0) : 0
        let hours = 8
        let colors: [NSColor] = attendanceKnown
            ? [.systemGreen, .systemYellow, .systemRed] : [.secondaryLabelColor]
        let segment = 360 / CGFloat(hours)
        let gap: CGFloat = hours > 1 ? 10 : 0
        func arc(_ hour: Int, _ fraction: Double, inner: CGFloat = 4.5, outer: CGFloat = 8.5) {
            guard fraction > 0 else { return }
            let start = 90 - CGFloat(hour) * segment - gap / 2
            let end = start - (segment - gap) * CGFloat(fraction)
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: outer, startAngle: start, endAngle: end, clockwise: true)
            path.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: inner, startAngle: end, endAngle: start, clockwise: false)
            path.close()
            path.fill()
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            for hour in 0..<hours {
                NSColor.white.setFill()
                arc(hour, 1, inner: finished ? 7 : 4.5)
                if waiting { continue }
                let capacity = 60.0
                for (lap, color) in colors.enumerated() {
                    let lapTarget = capacity * Double(hours)
                    let minutes = min(capacity, max(0, Double(actual) - Double(lap) * lapTarget - Double(hour) * capacity))
                    guard minutes > 0 else { continue }
                    color.setFill()
                    arc(hour, Double(minutes) / Double(capacity), inner: finished ? 7 : 4.5)
                }
            }
            if waiting {
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 7.5, y: 7.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func forwardRightClick(_ event: NSEvent) -> NSEvent? {
        guard event.type == .rightMouseDown,
              let view = event.window?.contentView?.hitTest(event.locationInWindow),
              let button = sequence(first: view, next: { $0.superview })
                .first(where: { $0 is NSStatusBarButton }) as? NSStatusBarButton else { return event }
        button.performClick(nil)
        return nil
    }
}

struct WorkOptionsWindow: View {
    @ObservedObject var model: WorkBarModel
    @ObservedObject var onboarding: OnboardingState
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Form {
            Section("계정") {
                AttendanceServicePicker(model: model)
                HStack {
                    Text(model.isRefreshing ? "근태 확인 중…"
                         : model.loginCompleted ? "\(model.selectedService.name) 연결됨"
                         : model.hasSavedSession ? "근태 확인 필요" : "로그인이 필요합니다")
                    Spacer()
                    if model.hasSavedSession {
                        Button("이 앱에서 로그아웃") { Task { await model.signOut() } }
                            .disabled(model.isSigningOut)
                    } else {
                        Button("로그인") {
                            let destination = onboarding.requestSignIn()
                            if destination == .signIn { model.beginSignIn() }
                            else { dismissWindow(id: "signIn") }
                            openWindow(id: destination.rawValue)
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        .disabled(model.isSigningOut)
                    }
                }
                if let message = model.loginFailureMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.hasSavedSession {
                        Button("다시 조회") { Task { await model.refresh() } }
                            .disabled(model.isSigningOut || model.isRefreshing)
                    }
                }
                if model.selectedService == .flex && model.hasSavedSession {
                    Button("flex 다시 로그인") {
                        model.beginSignIn()
                        openWindow(id: "signIn")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    .disabled(model.isSigningOut || model.isRefreshing)
                }
            }
            Section("출근 확인 알림") {
                HStack {
                    Toggle("알림 켜기", isOn: $model.remindersEnabled)
                    Button("알림 테스트") { Task { await model.testNotification() } }
                        .disabled(model.isTestingNotification)
                }
                Picker("기준 시각", selection: $model.reminderMode) {
                    Text("근무표 시작 기준").tag(ClockInReminderMode.scheduled)
                    Text("최근 출근 평균 기준").tag(ClockInReminderMode.average)
                }
                .disabled(!model.remindersEnabled)
                let reminderTime = model.snapshot?.clockInReminderTime(mode: model.reminderMode,
                    delayMinutes: model.reminderDelayMinutes) ?? "--:--"
                Stepper("기준 시각 \(model.reminderDelayMinutes)분 후 (\(reminderTime))", value: $model.reminderDelayMinutes,
                        in: 0...240)
                    .disabled(!model.remindersEnabled)
                if let message = model.reminderMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("앱 업데이트") {
                Toggle("새 버전 자동 확인", isOn: $updater.automaticChecks)
                Text(updater.message).font(.caption).foregroundStyle(.secondary)
                if !updater.availableCommits.isEmpty {
                    UpdateCommitList(commits: updater.availableCommits)
                }
                if updater.isInstalling {
                    ProgressView(value: Double(updater.installStep), total: Double(AppUpdater.installSteps.count))
                }
                HStack {
                    Button("업데이트 확인") { Task { await updater.check() } }
                        .disabled(updater.isChecking || updater.isInstalling)
                    if updater.availableRevision != nil {
                        Button("업데이트 설치") { updater.install() }
                            .disabled(updater.isChecking || updater.isInstalling)
                    }
                    if updater.installFailed {
                        Button("업데이트 로그") { NSWorkspace.shared.open(updater.logURL) }
                    }
                }
            }
            Section {
                HStack {
                    Button("새로고침") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing || model.isSigningOut)
                    Button("\(model.selectedService.name) 열기") {
                        NSWorkspace.shared.open(model.selectedService.webURL)
                    }
                    Button("사용 가이드") {
                        dismissWindow(id: "signIn")
                        onboarding.show()
                        openWindow(id: "onboarding")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                Button("종료") { NSApplication.shared.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)
    }
}

private enum MenuPalette {
    static let teal = Color(red: 39 / 255, green: 157 / 255, blue: 155 / 255)
    static let amber = Color(red: 244 / 255, green: 181 / 255, blue: 68 / 255)
    static let coral = Color(red: 232 / 255, green: 138 / 255, blue: 127 / 255)
    static func tealSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.16, green: 0.31, blue: 0.29)
                       : Color(red: 232 / 255, green: 245 / 255, blue: 242 / 255)
    }
    static func amberSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.34, green: 0.28, blue: 0.17)
                       : Color(red: 1, green: 243 / 255, blue: 219 / 255)
    }
    static func coralSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.34, green: 0.22, blue: 0.2)
                       : Color(red: 1, green: 240 / 255, blue: 237 / 255)
    }
    static func leaveSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.23, green: 0.26, blue: 0.35)
                       : Color(red: 0.91, green: 0.94, blue: 0.99)
    }

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 37 / 255, green: 36 / 255, blue: 34 / 255)
                       : Color(red: 250 / 255, green: 248 / 255, blue: 245 / 255)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 50 / 255, green: 49 / 255, blue: 47 / 255) : .white
    }
    static func warmCard(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 61 / 255, green: 55 / 255, blue: 43 / 255)
                       : Color(red: 1, green: 0.97, blue: 0.91)
    }
    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.94, green: 0.92, blue: 0.89)
                       : Color(red: 34 / 255, green: 37 / 255, blue: 43 / 255)
    }
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.7, green: 0.68, blue: 0.64)
                       : Color(red: 133 / 255, green: 129 / 255, blue: 125 / 255)
    }
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.1)
                       : Color(red: 237 / 255, green: 233 / 255, blue: 227 / 255)
    }
}

private struct MenuCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    var warm = false
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(warm ? MenuPalette.warmCard(colorScheme) : MenuPalette.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(MenuPalette.border(colorScheme), lineWidth: differentiateWithoutColor ? 1.5 : 0.7)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.035), radius: 8, y: 2)
    }
}

private extension View {
    func menuCard(warm: Bool = false, padding: CGFloat = 16) -> some View {
        modifier(MenuCard(warm: warm, padding: padding))
    }
}

struct WorkMenu: View {
    @ObservedObject var model: WorkBarModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MenuPalette.teal)
                Text("근무 캘린더").font(.headline.weight(.semibold))
                Text(model.selectedService == .flex ? "flex" : "원티드스페이스")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MenuPalette.secondary(colorScheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(MenuPalette.card(colorScheme), in: Capsule())
                Spacer(minLength: 4)
                if let snapshot = model.snapshot {
                    Text("\(snapshot.updatedAt, style: .time) 갱신")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(MenuPalette.secondary(colorScheme))
                        .lineLimit(1)
                }
                Button {
                    openWindow(id: "options")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 32, height: 32)
                        .background(MenuPalette.card(colorScheme), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .help("옵션")
                .accessibilityLabel("옵션 열기")
            }
            .frame(height: 36)
            if let snapshot = model.snapshot {
                HStack(alignment: .top, spacing: 12) {
                    AttendanceCalendarView(snapshot: snapshot, canEditLeave: model.loginCompleted, setLeave: model.setLeave)
                        .id("\(snapshot.service.rawValue)-\(snapshot.accountIdentifier)-\(snapshot.month.startDate)-\(snapshot.record?.date ?? "")")
                        .frame(width: 350, height: 528, alignment: .top)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            TodaySummary(snapshot: snapshot).menuCard(warm: true)
                            MonthSummary(snapshot: snapshot).menuCard()
                            CalculationDetails(snapshot: snapshot).menuCard(padding: 14)
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(width: 334, height: 528)
                }
            } else {
                Label(model.message, systemImage: "calendar.badge.exclamationmark")
                    .font(.callout).foregroundStyle(MenuPalette.secondary(colorScheme))
                    .padding(.vertical, 24)
            }
            if model.snapshot != nil && model.message != "방금 업데이트됨" {
                Text(model.message)
                    .font(.caption2).foregroundStyle(MenuPalette.secondary(colorScheme))
                    .lineLimit(2)
            }
        }
        .foregroundStyle(MenuPalette.text(colorScheme))
        .padding(16)
        .frame(width: model.snapshot == nil ? 400 : 728,
               height: model.snapshot == nil ? nil : 650, alignment: .topLeading)
        .background(MenuPalette.canvas(colorScheme))
    }
}

struct AttendanceCalendarMonth {
    let calendar: Calendar
    let formatter: DateFormatter
    let start: Date
    let days: [Date?]
    let firstAllowedMonth: Date
    let lastAllowedMonth: Date
    let referenceDate: Date

    init(snapshot: AttendanceSnapshot, displaying date: Date? = nil) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = snapshot.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = snapshot.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let reference = snapshot.record.flatMap { formatter.date(from: $0.date) } ?? snapshot.updatedAt
        let first = formatter.date(from: snapshot.month.startDate) ?? reference
        let last = formatter.date(from: snapshot.month.endDate) ?? reference
        // Include an ongoing shift even when it began before the reporting period.
        firstAllowedMonth = calendar.dateInterval(of: .month, for: min(first, reference))!.start
        lastAllowedMonth = calendar.dateInterval(of: .month, for: max(last, max(reference, snapshot.updatedAt)))!.start
        let requested = calendar.dateInterval(of: .month, for: date ?? reference)!.start
        let start = min(max(requested, firstAllowedMonth), lastAllowedMonth)
        self.start = start
        let leading = calendar.component(.weekday, from: start) - 1
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        let dates = (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start) }
        days = Array(repeating: nil, count: leading) + dates
            + Array(repeating: nil, count: 42 - leading - count)
        self.calendar = calendar
        self.formatter = formatter
        referenceDate = reference
    }

    var title: String { "\(calendar.component(.year, from: start))년 \(calendar.component(.month, from: start))월" }
    func key(_ date: Date) -> String { formatter.string(from: date) }
    func adjacentMonth(_ offset: Int) -> Date? {
        guard let date = calendar.date(byAdding: .month, value: offset, to: start),
              date >= firstAllowedMonth, date <= lastAllowedMonth else { return nil }
        return date
    }
}

struct CalendarDayDetail {
    let snapshot: AttendanceSnapshot
    let key: String

    let record: DailyRecord?

    init(snapshot: AttendanceSnapshot, key: String) {
        self.snapshot = snapshot
        self.key = key
        record = snapshot.record?.date == key ? snapshot.record : snapshot.calendarRecords.first { $0.date == key }
    }
    var holiday: String? {
        if let leave = snapshot.leaveByDate[key] { return leave.title }
        if let holiday = snapshot.calendarHolidays[key] { return holiday.name }
        return nil
    }
    var status: String {
        if snapshot.record?.date == key && !snapshot.attendanceKnown { return "근태 확인 불가" }
        if let record, record.isWorking { return "근무 중" }
        if let record, record.end?.isEmpty == false { return "근무 완료" }
        if let holiday { return holiday }
        if let record {
            if record.isScheduledWorkday { return "근무일" }
            if record.isScheduledDayOff { return "휴무" }
        }
        return "기록 없음"
    }
    var minutes: Int? {
        if snapshot.record?.date == key && !snapshot.attendanceKnown { return nil }
        guard let record, let minutes = record.totalMinutes,
              minutes > 0 || record.start?.isEmpty == false else { return nil }
        return minutes
    }
    var remainingRequiredMinutes: Int? {
        guard snapshot.attendanceKnown, record?.isScheduledWorkday == true,
              record?.start?.isEmpty != false, minutes == nil, holiday == nil,
              key >= snapshot.month.startDate, key <= snapshot.month.endDate else { return nil }
        return snapshot.dailyRequiredHours.map { Int(ceil($0 * 60)) }
    }
}

struct AttendanceCalendarView: View {
    let snapshot: AttendanceSnapshot
    let canEditLeave: Bool
    let setLeave: (LeaveOptions?, String) -> Void
    @State private var displayedMonth: Date?
    @State private var selectedDate: Date?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let month = AttendanceCalendarMonth(snapshot: snapshot, displaying: displayedMonth)
        let selection = selectedDate ?? month.referenceDate
        let selectedKey = month.key(selection)
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(month.title)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Spacer(minLength: 0)
                    ForEach([-1, 0, 1], id: \.self) { offset in
                        Button {
                            if offset == 0 {
                                displayedMonth = snapshot.updatedAt
                                selectedDate = snapshot.updatedAt
                            } else if let date = month.adjacentMonth(offset) {
                                displayedMonth = date
                                selectedDate = date
                            }
                        } label: {
                            Group {
                                if offset == 0 {
                                    Text("오늘").font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                } else {
                                    Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                                        .font(.caption.weight(.semibold)).frame(width: 28)
                                }
                            }
                            .frame(height: 28)
                            .background(MenuPalette.canvas(colorScheme), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .disabled(offset != 0 && month.adjacentMonth(offset) == nil)
                        .opacity(offset != 0 && month.adjacentMonth(offset) == nil ? 0.4 : 1)
                        .accessibilityLabel(offset == 0 ? "오늘" : offset < 0 ? "이전 달" : "다음 달")
                    }
                }
                Text("조회 기간 \(snapshot.month.startDate) – \(snapshot.month.endDate)")
                    .font(.system(size: 10)).foregroundStyle(MenuPalette.secondary(colorScheme))
                    .lineLimit(1).minimumScaleFactor(0.8)
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { index, day in
                            Text(day).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(index == 0 ? MenuPalette.coral : MenuPalette.secondary(colorScheme))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Grid(horizontalSpacing: 3, verticalSpacing: 2) {
                        ForEach(0..<(month.days.count / 7), id: \.self) { week in
                            GridRow {
                                ForEach(0..<7, id: \.self) { weekday in
                                    if let date = month.days[week * 7 + weekday] {
                                        dayCell(date, month: month, selectedKey: selectedKey)
                                    } else {
                                        Color.clear.frame(height: 35).accessibilityHidden(true)
                                    }
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 0) {
                    legend("근무", color: MenuPalette.teal)
                    Spacer(minLength: 2)
                    legend("진행 중", color: MenuPalette.amber)
                    Spacer(minLength: 2)
                    legend("휴무", color: MenuPalette.coral)
                    Spacer(minLength: 2)
                    legend("휴가", color: Color(red: 0.49, green: 0.58, blue: 0.81))
                    Spacer(minLength: 2)
                    legend("달성", color: MenuPalette.secondary(colorScheme))
                }
                .padding(.top, 1)
            }
            .menuCard(padding: 12)
            .frame(height: 338)
            selectedDay(CalendarDayDetail(snapshot: snapshot, key: selectedKey), date: selection, month: month)
                .menuCard(padding: 12)
                .frame(height: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(differentiateWithoutColor ? MenuPalette.text(colorScheme) : .clear, lineWidth: 1))
            Text(title).font(.system(size: 9)).foregroundStyle(MenuPalette.secondary(colorScheme))
        }
        .accessibilityElement(children: .combine)
    }

    private func dayCell(_ date: Date, month: AttendanceCalendarMonth, selectedKey: String) -> some View {
        let key = month.key(date)
        let detail = CalendarDayDetail(snapshot: snapshot, key: key)
        let selected = key == selectedKey
        let today = month.calendar.isDate(date, inSameDayAs: snapshot.updatedAt)
        let working = detail.record?.isWorking == true
        let leave = snapshot.leaveByDate[key] != nil
        let off = detail.record?.isScheduledDayOff == true || (detail.holiday != nil && !leave)
        let remaining = detail.remainingRequiredMinutes
        let requirement = remaining.map {
            $0 > 0
                ? "하루 평균 \(AttendanceSnapshot.duration($0)) 필요"
                : "현재 \(snapshot.monthTitle) 필수근무 달성"
        }
        let value: String
        if let minutes = detail.minutes {
            let time = String(format: "%d:%02d", minutes / 60, minutes % 60)
            value = working ? "중 \(time)" : time
        } else if leave {
            value = "휴가"
        } else if let remaining {
            value = remaining > 0
                ? String(format: "-%d:%02d", remaining / 60, remaining % 60)
                : "달성"
        } else if off || detail.holiday != nil {
            value = "휴무"
        } else {
            value = "—"
        }
        let fill = selected ? MenuPalette.teal
            : working ? MenuPalette.amberSoft(colorScheme)
            : leave ? MenuPalette.leaveSoft(colorScheme)
            : off ? MenuPalette.coralSoft(colorScheme)
            : detail.minutes != nil ? MenuPalette.tealSoft(colorScheme)
            : remaining == 0 ? MenuPalette.tealSoft(colorScheme)
            : Color.clear
        return Button { selectedDate = date } label: {
            VStack(spacing: 2) {
                Text("\(month.calendar.component(.day, from: date))")
                    .font(.system(size: 13, weight: selected || today ? .bold : .medium, design: .rounded))
                    .foregroundStyle(selected ? .white : off ? MenuPalette.coral : MenuPalette.text(colorScheme))
                Text(value)
                    .font(.system(size: 8.5, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(selected ? Color.white.opacity(0.95)
                        : working ? MenuPalette.amber
                        : leave ? Color(red: 0.49, green: 0.58, blue: 0.81)
                        : off ? MenuPalette.coral
                        : detail.minutes != nil || remaining == 0 ? MenuPalette.teal
                        : MenuPalette.secondary(colorScheme))
            }
            .frame(maxWidth: .infinity).frame(height: 35)
            .background(fill, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(today ? MenuPalette.amber
                        : selected && differentiateWithoutColor ? MenuPalette.text(colorScheme)
                        : selected ? MenuPalette.teal : .clear,
                        lineWidth: today || differentiateWithoutColor ? 1.5 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(key), \(detail.status)")
        .accessibilityValue(requirement ?? detail.minutes.map(AttendanceSnapshot.duration) ?? value)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(key) · \(requirement ?? detail.status)")
    }

    private func selectedDay(_ detail: CalendarDayDetail, date: Date, month: AttendanceCalendarMonth) -> some View {
        let isToday = month.calendar.isDate(date, inSameDayAs: snapshot.updatedAt)
        let editable = canEditLeave && detail.key >= snapshot.month.startDate &&
            detail.key <= snapshot.month.endDate &&
            snapshot.calendarRecords.contains { $0.date == detail.key }
        let clockText = detail.record.map { record in
            detail.key == snapshot.record?.date ? snapshot.attendanceDescription :
                "출근 \(AttendanceSnapshot.clock(record.start)) · 퇴근 \(AttendanceSnapshot.clock(record.end))"
        } ?? "출근 --:-- · 퇴근 --:--"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(month.calendar.component(.month, from: date))월 \(month.calendar.component(.day, from: date))일")
                    .font(.system(size: 15, weight: .semibold))
                if isToday {
                    Text("오늘")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MenuPalette.teal)
                }
                Spacer(minLength: 4)
                Text(detail.holiday ?? detail.status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(detail.holiday != nil ? MenuPalette.coral : MenuPalette.teal)
                    .lineLimit(1).help(detail.holiday ?? detail.status)
            }
            HStack(spacing: 6) {
                Image(systemName: "clock").foregroundStyle(MenuPalette.teal)
                Text(clockText).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 11))
            .foregroundStyle(MenuPalette.secondary(colorScheme))
            Divider().overlay(MenuPalette.border(colorScheme))
            HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 3) {
                    leavePicker("소정근로 인정", field: \.recognizesScheduledWork, date: detail.key)
                    leavePicker("초과근로 반영", field: \.recognizesOvertime, date: detail.key)
                }
                Button {
                    setLeave(nil, detail.key)
                } label: {
                    Label("휴가 없음", systemImage: "calendar.badge.minus")
                        .font(.system(size: 10, weight: .medium))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(MenuPalette.teal)
                .disabled(!editable || snapshot.leaveByDate[detail.key] == nil)
                .help("선택 날짜의 휴가 처리 설정을 지웁니다")
            }
            .disabled(!editable)
            .opacity(editable ? 1 : 0.55)
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text("앱 내 계산에만 반영 · 회사에 신청하지 않음")
            }
            .font(.system(size: 9))
            .foregroundStyle(MenuPalette.secondary(colorScheme))
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 156, alignment: .top)
    }

    private func leavePicker(_ title: String, field: WritableKeyPath<LeaveOptions, Bool>, date: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 9, weight: .medium)).frame(width: 105, alignment: .leading)
            Picker(title, selection: Binding<Bool?>(
                get: { snapshot.leaveByDate[date].map { $0[keyPath: field] } },
                set: { value in
                    if let value {
                        var options = snapshot.leaveByDate[date] ?? LeaveOptions()
                        options[keyPath: field] = value
                        setLeave(options, date)
                    }
                })) {
                    Text("인정").tag(Optional(true))
                    Text("제외").tag(Optional(false))
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .controlSize(.small)
                .pickerStyle(.segmented)
                .frame(width: 112)
                .accessibilityLabel("\(date) \(title)")
        }
    }
}

struct TodaySummary: View {
    let snapshot: AttendanceSnapshot

    @Environment(\.colorScheme) private var colorScheme

    private var status: String {
        guard snapshot.attendanceKnown else { return "근태 확인 불가" }
        if snapshot.record?.isWorking == true { return "근무 중" }
        if snapshot.record?.end?.isEmpty == false { return "근무 완료" }
        if snapshot.record?.isScheduledWorkday == false { return "휴무일" }
        return snapshot.record == nil ? "기록 없음" : "출근 전"
    }

    var body: some View {
        let meter = snapshot.todayMeter
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("오늘").font(.system(size: 16, weight: .semibold))
                    Text(snapshot.updatedAt.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated)))
                        .font(.system(size: 11)).foregroundStyle(MenuPalette.secondary(colorScheme))
                }
                Spacer(minLength: 2)
                HStack(spacing: 5) {
                    Circle().fill(status == "근무 중" ? MenuPalette.amber : MenuPalette.teal)
                        .frame(width: 7, height: 7)
                    Text(status).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(status == "근무 중" ? MenuPalette.amber : MenuPalette.teal)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(status == "근무 중" ? MenuPalette.amberSoft(colorScheme) : MenuPalette.tealSoft(colorScheme),
                            in: Capsule())
                .accessibilityElement(children: .combine)
            }
            Text(AttendanceSnapshot.duration(snapshot.todayMinutes))
                .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack {
                Text("기준 8시간 0분")
                    .font(.system(size: 12)).foregroundStyle(MenuPalette.secondary(colorScheme))
                Spacer()
                if snapshot.attendanceKnown {
                    Text("\(meter.percent)% 달성")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MenuPalette.teal)
                }
            }
            if snapshot.attendanceKnown {
                WorkProgressBar(fill: Double(meter.actualMinutes) / Double(meter.targetMinutes), markers: [],
                                value: "8시간 기준 \(meter.percent)%",
                                label: "오늘 근무시간 진행률")
            } else {
                ProgressView(value: 0)
                    .tint(MenuPalette.teal)
                    .accessibilityLabel("오늘 근무시간 진행률 확인 불가")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "clock").foregroundStyle(MenuPalette.teal)
                Text(snapshot.attendanceDescription)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .font(.system(size: 11))
            .foregroundStyle(MenuPalette.secondary(colorScheme))
            if let note = snapshot.attendanceNote {
                Text(note).font(.system(size: 10)).foregroundStyle(MenuPalette.secondary(colorScheme))
            }
        }
    }
}

struct MonthSummary: View {
    let snapshot: AttendanceSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let monthNumber = Int(snapshot.month.startDate.dropFirst(5).prefix(2))
        let meter = snapshot.monthMeter
        let fill = meter.targetMinutes > 0 ? Double(max(0, meter.actualMinutes)) / Double(meter.targetMinutes) : 0
        let average = snapshot.dailyRequiredHours.map { AttendanceSnapshot.duration(Int(ceil($0 * 60))) } ?? "—"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "calendar").foregroundStyle(MenuPalette.teal)
                Text(snapshot.monthTitle).font(.system(size: 16, weight: .semibold))
                if let monthNumber {
                    Text("\(monthNumber)월").font(.system(size: 12))
                        .foregroundStyle(MenuPalette.secondary(colorScheme))
                }
                Spacer(minLength: 2)
                Text("필수시간 대비 \(meter.percent)%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(meter.percent >= 100 ? MenuPalette.teal : MenuPalette.secondary(colorScheme))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(meter.percent >= 100 ? MenuPalette.tealSoft(colorScheme) : MenuPalette.canvas(colorScheme),
                                in: Capsule())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(AttendanceSnapshot.duration(snapshot.displayMonth.actualMinutes))
                    .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("누적 근무시간").font(.system(size: 11)).foregroundStyle(MenuPalette.secondary(colorScheme))
            }
            WorkProgressBar(
                fill: fill,
                markers: [],
                value: "\(meter.percent)%",
                label: "월 필수 근무시간 진행률"
            )
            HStack(spacing: 8) {
                metric("남은 근무일", value: "\(snapshot.remainingRequiredWorkDays)일", symbol: "calendar")
                metric("하루 필요", value: average, symbol: "target")
            }
            Text("퇴근 전 오늘 포함 · 남은 필수시간 기준")
                .font(.system(size: 9)).foregroundStyle(MenuPalette.secondary(colorScheme))
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(MenuPalette.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(MenuPalette.secondary(colorScheme))
                Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 8)
        .background(MenuPalette.tealSoft(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct CalculationDetails: View {
    let snapshot: AttendanceSnapshot
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let month = snapshot.displayMonth
        let compensation = snapshot.displayCompensationEstimate
        let holiday = snapshot.leaveDeduction?.maximumMinutes ?? 0
        let range = holiday + max(month.maximumWorkMinutes ?? 0,
                                 max(month.targetMinutes, compensation?.thresholdMinutes ?? 0))
        let meter = WorkMeter(actualMinutes: month.creditedMinutes, targetMinutes: range)
        let confirmedMeter = WorkMeter(actualMinutes: snapshot.month.creditedMinutes, targetMinutes: range)
        let holidayMeter = WorkMeter(actualMinutes: holiday, targetMinutes: range)
        let liveValue = snapshot.liveWorkClock == nil ? "" :
            ", 확정 \(AttendanceSnapshot.duration(snapshot.month.creditedMinutes)), 진행 중 \(AttendanceSnapshot.duration(max(0, month.creditedMinutes - snapshot.month.creditedMinutes)))"
        let pace = snapshot.paceDifferenceMinutes
        let markers: [(position: Double?, color: Color, description: String)] = [
            (range > 0 ? Double(snapshot.expectedMinutesByNow) / Double(range) : 0, .red,
             "\(snapshot.dayTitle)까지 기준 \(AttendanceSnapshot.duration(snapshot.expectedMinutesByNow)) · " +
             "\(AttendanceSnapshot.duration(abs(pace))) \(pace >= 0 ? "앞섬" : "부족")"),
            (range > 0 ? Double(month.targetMinutes) / Double(range) : 0, .blue,
             month.balance >= 0
              ? "필수 근무시간 - \(AttendanceSnapshot.duration(month.balance)) 초과"
              : "필수 근무시간 - **\(AttendanceSnapshot.duration(month.remainingMinutes))**"),
            (compensation.map { range > 0 ? Double($0.thresholdMinutes) / Double(range) : 0 }, .purple,
             compensation.map {
                 $0.remainingMinutes > 0
                  ? "수당 기준 - **\(AttendanceSnapshot.duration($0.remainingMinutes))**"
                  : "수당 기준 - \(AttendanceSnapshot.duration($0.excessMinutes)) 초과"
             } ?? "수당 기준 확인 불가")
        ]
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("퇴근 전 오늘 포함 · 남은 필수시간 기준")
                    .font(.system(size: 10)).foregroundStyle(MenuPalette.secondary(colorScheme))
                WorkProgressBar(fill: meter.fillFraction, markers: markers,
                                value: "필수시간 반영 \(AttendanceSnapshot.duration(month.creditedMinutes)), 필수시간 대비 \(snapshot.monthMeter.percent)%" + liveValue,
                                label: "월간 누적 근무시간", confirmedFill: confirmedMeter.fillFraction,
                                holidayFill: holidayMeter.fillFraction)
                ForEach(markers.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 7))
                            .foregroundStyle(markers[index].color).accessibilityHidden(true)
                        Text(LocalizedStringKey(markers[index].description))
                            .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let maximum = snapshot.month.maximumWorkMinutes {
                    Text("최대 \(AttendanceSnapshot.duration(maximum))")
                        .font(.system(size: 10)).foregroundStyle(MenuPalette.secondary(colorScheme))
                }
                if let deduction = snapshot.leaveDeduction, !deduction.dates.isEmpty {
                    let dates = deduction.dates.map { date in
                        let parts = date.split(separator: "-").compactMap { Int($0) }
                        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : date
                    }
                    Label("휴가 \(dates.joined(separator: ", ")) · −\(AttendanceSnapshot.duration(deduction.minutes))",
                          systemImage: "circle.fill")
                        .font(.system(size: 10)).foregroundStyle(MenuPalette.secondary(colorScheme))
                }
            }
            .padding(.top, 8)
        } label: {
            Label("계산 기준 상세", systemImage: "chart.bar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MenuPalette.text(colorScheme))
        }
        .tint(MenuPalette.teal)
        .accessibilityIdentifier("calculation-details")
        .accessibilityValue(expanded ? "펼침" : "접힘")
    }
}

struct WorkProgressBar: View {
    static let confirmedColor = MenuPalette.teal
    static let holidayColor = Color.black
    static let ongoingColor = MenuPalette.amber
    let fill: Double
    let markers: [(position: Double?, color: Color, description: String)]
    let value: String
    let label: String
    var confirmedFill: Double? = nil
    var holidayFill: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let boundedFill = min(1, max(0, fill))
            let confirmed = min(boundedFill, max(0, confirmedFill ?? boundedFill))
            let holiday = min(1, max(0, holidayFill))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.gray.opacity(0.18))
                    .frame(height: 8)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(Self.holidayColor)
                        .frame(width: geometry.size.width * holiday)
                }
                .frame(width: geometry.size.width, height: 8)
                .clipShape(Capsule())
                HStack(spacing: 0) {
                    Rectangle().fill(Self.confirmedColor)
                        .frame(width: geometry.size.width * confirmed)
                    Rectangle().fill(Self.ongoingColor)
                        .frame(width: geometry.size.width * (boundedFill - confirmed))
                }
                .frame(width: geometry.size.width * boundedFill, height: 8)
                .clipShape(Capsule())
                if fill > 1 {
                    Capsule().fill(.yellow)
                        .frame(width: geometry.size.width * min(1, fill - 1), height: 8)
                }
                if fill > 2 {
                    Capsule().fill(.red)
                        .frame(width: geometry.size.width * min(1, fill - 2), height: 8)
                }
                ForEach(markers.indices, id: \.self) { index in
                    if let position = markers[index].position {
                        let matching = markers.indices.filter { markers[$0].position == position }
                        let height = 14 / CGFloat(matching.count)
                        Path { path in
                            path.move(to: CGPoint(x: 0.5, y: 0))
                            path.addLine(to: CGPoint(x: 0.5, y: height))
                        }
                            .stroke(markers[index].color,
                                    style: StrokeStyle(lineWidth: 1, dash: fill >= position ? [2, 2] : []))
                            .frame(width: 1, height: height)
                            .offset(x: min(geometry.size.width - 1,
                                           max(0, geometry.size.width * position - 0.5)),
                                    y: -7 + height * (CGFloat(matching.firstIndex(of: index)!) + 0.5))
                    }
                }
            }
            .frame(height: 14)
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(([value] + markers.map { $0.description.replacingOccurrences(of: "**", with: "") }).joined(separator: ", "))
    }
}
