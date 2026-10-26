import Foundation
import Security
import AppKit
import SwiftUI
import WebKit
import UserNotifications

final class StatusClickRecorder: NSObject {
    var count = 0
    @objc func click() { count += 1 }
}

@MainActor
@main
struct LoginTests {
    static func main() async throws {
        try await flexWebLoginCookieChangeChecks()
        try await flexWebLogoutChecks()
        let epoch = SessionEpoch()
        _ = epoch.begin()
        async let firstWaiter = epoch.quiesce()
        async let secondWaiter = epoch.quiesce()
        await Task.yield()
        await Task.yield()
        epoch.finish()
        await firstWaiter
        await secondWaiter
        await notificationChecks()
        try await flexServiceChecks()
        try await legacyPurgeFailureChecks()
        try await liveProgressChecks()
        let vault = KeychainSession(service: "ai.wantedspace.WorkBar.Tests.Login.\(UUID().uuidString)")
        let defaultsSuite = "geuntae-login-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.set(false, forKey: "clockInRemindersEnabled")
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defer { try? vault.delete() }
        let storage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "workbar-login-tests-\(UUID().uuidString)")
        defer { for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) } }
        let cookie = HTTPCookie(properties: [
            .name: "login-test", .value: "test-session", .domain: "api.handyspace.ai", .path: "/"
        ])!
        _ = try vault.save([cookie])
        let month = MonthlyReport(workedMinutes: 0, outsideMinutes: 0, requiredMinutes: 480,
                                  vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
                                  startDate: "2026-09-01", endDate: "2026-09-30",
                                  maximumWorkMinutes: nil)
        let snapshot = AttendanceSnapshot(record: nil, month: month,
                                           remainingWorkDays: 0, updatedAt: Date())
        var fetchError: Error?
        var saveError: Error?
        var saveCount = 0
        let model = WorkBarModel(wantedSpace: WantedSpaceBackend(vault: vault, client: AttendanceClient(cookies: storage),
                                 snapshotLoader: { _ in
            if let fetchError { throw fetchError }
            return snapshot
        }, sessionSaver: { cookies in
            if let saveError { throw saveError }
            _ = try vault.save(cookies)
            saveCount += 1
        }), defaults: defaults)
        // Restoring cookies alone must not display a successful connection.
        precondition(model.hasSavedSession && !model.loginCompleted && model.snapshot == nil)
        let restored = await model.refresh()
        precondition(restored && model.loginCompleted && model.snapshot != nil && saveCount == 1)

        // A failed new login cannot reuse the previous successful snapshot.
        model.beginSignIn()
        precondition(!model.loginCompleted)
        fetchError = URLError(.notConnectedToInternet)
        await model.acceptCookies([cookie])
        precondition(!model.loginCompleted && model.snapshot != nil && saveCount == 1)
        precondition(model.message.hasPrefix("업데이트 실패:"))
        precondition(model.loginFailureMessage == "근태 정보를 연결하지 못했어요. 연결을 확인하고 다시 시도해주세요.")

        // Even a successful fetch is not a successful login if Keychain saving fails.
        fetchError = nil
        saveError = KeychainError(-25291)
        await model.acceptCookies([cookie])
        precondition(!model.loginCompleted && saveCount == 1)
        precondition(model.loginFailureMessage?.contains("키체인") == true)
        saveError = nil
        await model.acceptCookies([cookie])
        precondition(model.loginCompleted && saveCount == 2)
        precondition(model.loginFailureMessage == nil)
        let saved = try vault.load()
        precondition(saved.first?.value == "test-session")

        fetchError = AttendanceError.signInRequired
        let expired = await model.refresh()
        precondition(!expired && !model.loginCompleted && !model.hasSavedSession && model.snapshot == nil)
        precondition(model.loginFailureMessage == "로그인 정보를 확인하지 못했어요. 다시 로그인해주세요.")
        let removed = try vault.load()
        precondition(removed.isEmpty)

        // A response from before retrying must not complete the new attempt or save cookies.
        var pending: CheckedContinuation<AttendanceSnapshot, Never>?
        let delayed = WorkBarModel(wantedSpace: WantedSpaceBackend(vault: vault, client: AttendanceClient(cookies: storage),
                                   snapshotLoader: { _ in
            await withCheckedContinuation { pending = $0 }
        }, sessionSaver: { _ in saveCount += 1 }), defaults: defaults)
        let request = Task { await delayed.acceptCookies([cookie]) }
        while pending == nil { await Task.yield() }
        precondition(delayed.isRefreshing && !delayed.loginCompleted)
        delayed.beginSignIn()
        pending?.resume(returning: snapshot)
        await request.value
        precondition(!delayed.loginCompleted && delayed.snapshot == nil && !delayed.isRefreshing)
        precondition(saveCount == 2)

        // Logout waits for a late response, then clears the actual client's and WebKit's cookies.
        let logoutVault = KeychainSession(service: "ai.wantedspace.WorkBar.Tests.Logout.\(UUID().uuidString)")
        defer { try? logoutVault.delete() }
        _ = try logoutVault.save([cookie])
        let webDataStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(webDataStore) {} }
        let webStore = webDataStore.httpCookieStore
        let unrelated = HTTPCookie(properties: [
            .name: "unrelated", .value: "keep", .domain: "example.com", .path: "/"
        ])!
        storage.setCookie(unrelated)
        await webStore.setCookie(cookie)
        await webStore.setCookie(unrelated)
        let startingBrowserCookies = await webStore.allCookies()
        precondition(startingBrowserCookies.contains { $0.name == cookie.name })
        precondition(startingBrowserCookies.contains { $0.name == "unrelated" })
        var lateResponse: CheckedContinuation<AttendanceSnapshot, Never>?
        var logoutLoads = 0
        var logoutSaves = 0
        let logoutModel = WorkBarModel(wantedSpace: WantedSpaceBackend(vault: logoutVault, client: AttendanceClient(cookies: storage),
                                       webDataStore: webDataStore, snapshotLoader: { _ in
            logoutLoads += 1
            let fresh: AttendanceSnapshot
            if logoutLoads == 1 {
                fresh = await withCheckedContinuation { lateResponse = $0 }
            } else {
                fresh = snapshot
            }
            storage.setCookie(cookie)
            return fresh
        }, sessionSaver: { cookies in
            _ = try logoutVault.save(cookies)
            logoutSaves += 1
        }), defaults: defaults)
        let inFlight = Task { await logoutModel.refresh() }
        while lateResponse == nil { await Task.yield() }
        let logout = Task { await logoutModel.signOut() }
        while !logoutModel.isSigningOut { await Task.yield() }
        lateResponse?.resume(returning: snapshot)
        let staleSucceeded = await inFlight.value
        await logout.value
        let logoutCookies = try logoutVault.load()
        let browserCookies = await webStore.allCookies()
        precondition(!staleSucceeded && !logoutModel.isSigningOut && !logoutModel.isRefreshing)
        precondition(logoutModel.snapshot == nil && !logoutModel.hasSavedSession && !logoutModel.loginCompleted)
        precondition(logoutCookies.isEmpty && logoutSaves == 0)
        precondition(!browserCookies.contains { SavedCookie($0).belongsToWantedSpace })
        precondition(!(storage.cookies ?? []).contains { SavedCookie($0).belongsToWantedSpace })
        precondition(browserCookies.contains { $0.name == "unrelated" })
        precondition((storage.cookies ?? []).contains { $0.name == "unrelated" })

        await logoutModel.acceptCookies([cookie])
        let signedOutRefresh = await logoutModel.refresh()
        precondition(!signedOutRefresh && logoutLoads == 1 && !logoutModel.hasSavedSession)
        logoutModel.beginSignIn()
        await logoutModel.acceptCookies([cookie])
        precondition(logoutModel.loginCompleted && logoutModel.hasSavedSession && logoutSaves == 1)
        await logoutModel.signOut()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        var pageState = LoginWebView.LoadState.loading
        let coordinator = LoginWebView.Coordinator(model: model) { pageState = $0 }
        coordinator.webView(webView, didFinish: nil)
        precondition(pageState == .ready)
        coordinator.webView(webView, didFail: nil, withError: URLError(.cancelled))
        precondition(pageState == .ready)
        coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        guard case .failed = pageState else { preconditionFailure("Missing navigation error") }
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        precondition(pageState == .loading)
        coordinator.webView(webView, didFinish: nil)
        precondition(pageState == .ready)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = statusItem.button!
        let window = button.window!
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1)!
        // Right-click uses the same button action as left-click, without a context menu.
        let clicks = StatusClickRecorder()
        button.target = clicks
        button.action = #selector(StatusClickRecorder.click)
        precondition(LaunchLabel.forwardRightClick(rightClick) == nil)
        precondition(clicks.count == 1 && statusItem.menu == nil)
        button.performClick(nil)
        precondition(clicks.count == 2)

        fetchError = nil
        let connected = await model.refresh()
        precondition(connected && model.hasSavedSession)

        // A temporary fetch failure does not require logging in again.
        fetchError = URLError(.notConnectedToInternet)
        let offline = await model.refresh()
        precondition(!offline && model.hasSavedSession && !model.loginCompleted)

        fetchError = AttendanceError.signInRequired
        let sessionExpired = await model.refresh()
        precondition(!sessionExpired && !model.hasSavedSession)
        let leftClick = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                            modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(LaunchLabel.forwardRightClick(leftClick) === leftClick)
        let outsideClick = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: -10, y: -10),
                                               modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(LaunchLabel.forwardRightClick(outsideClick) === outsideClick)
        precondition(clicks.count == 2)

        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let optionsClick = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 20),
                                              modifierFlags: [], timestamp: 0,
                                              windowNumber: otherWindow.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(LaunchLabel.forwardRightClick(optionsClick) === optionsClick)
        precondition(clicks.count == 2)
        otherWindow.close()

        // Full windows appear in Cmd-Tab; the menu bar panel alone stays hidden.
        let app = NSApplication.shared
        let delegate = WorkBarAppDelegate()
        let update = Notification(name: NSApplication.didUpdateNotification, object: app)
        let login = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
        let guide = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [login, guide, panel] { window.isReleasedWhenClosed = false }
        app.setActivationPolicy(.accessory)
        panel.orderFront(nil)
        delegate.applicationDidUpdate(update)
        precondition(app.activationPolicy() == .accessory)
        login.orderFront(nil)
        delegate.applicationDidUpdate(update)
        precondition(app.activationPolicy() == .regular)
        guide.orderFront(nil)
        login.close()
        delegate.applicationDidUpdate(update)
        precondition(app.activationPolicy() == .regular)
        guide.close()
        delegate.applicationDidUpdate(update)
        precondition(app.activationPolicy() == .accessory)
        login.orderFront(nil)
        delegate.applicationDidUpdate(update)
        precondition(app.activationPolicy() == .regular)
        login.close()
        panel.close()
        delegate.applicationDidUpdate(update)
        precondition(app.activationPolicy() == .accessory)
        print("Login checks passed")
    }

    static func notificationChecks() async {
        let suite = "geuntae-notification-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "clockInRemindersEnabled")
        let reminderKey = Preferences(defaults: defaults).reminderDayKey(account: "wantedSpace-test")
        defaults.set("2026-10-07", forKey: reminderKey)
        var status = UNAuthorizationStatus.authorized
        var granted = true
        var permissionError: Error?
        var sendError: Error?
        var permissionRequests = 0
        var notifications: [UNNotificationRequest] = []
        var pending: CheckedContinuation<Void, Never>?
        var hold = false
        let model = WorkBarModel(wantedSpace: WantedSpaceBackend(vault: KeychainSession(service: suite)),
            defaults: defaults, notificationAuthorizationStatus: { status },
            requestNotificationAuthorization: {
                permissionRequests += 1
                if let permissionError { throw permissionError }
                return granted
            }, sendNotification: {
                if hold { await withCheckedContinuation { pending = $0 } }
                if let sendError { throw sendError }
                notifications.append($0)
            })
        precondition(!model.remindersEnabled && !model.hasSavedSession)
        await model.testNotification()
        precondition(permissionRequests == 0 && notifications.count == 1 && !model.isTestingNotification)
        let request = notifications[0]
        precondition(request.identifier == "geuntae-bar-notification-test" && request.trigger == nil)
        precondition(request.content.title == "Geuntae bar 알림 테스트" && request.content.sound != nil)
        precondition(model.reminderMessage?.contains("보냈어요") == true)
        precondition(defaults.string(forKey: reminderKey) == "2026-10-07" && !model.remindersEnabled)

        status = .notDetermined
        await model.testNotification()
        precondition(permissionRequests == 1 && notifications.count == 2)
        granted = false
        await model.testNotification()
        precondition(permissionRequests == 2 && notifications.count == 2)
        precondition(model.reminderMessage?.contains("macOS 알림 설정") == true)
        status = .denied
        await model.testNotification()
        precondition(permissionRequests == 2 && notifications.count == 2)
        precondition(model.reminderMessage?.contains("허용해주세요") == true)

        status = .notDetermined
        permissionError = CocoaError(.fileReadUnknown)
        await model.testNotification()
        precondition(notifications.count == 2 && model.reminderMessage?.contains("권한 요청 실패") == true)
        status = .authorized
        sendError = CocoaError(.fileWriteUnknown)
        await model.testNotification()
        precondition(notifications.count == 2 && model.reminderMessage?.contains("전송 실패") == true)
        precondition(!model.isTestingNotification)

        sendError = nil
        hold = true
        let testing = Task { await model.testNotification() }
        while pending == nil { await Task.yield() }
        precondition(model.isTestingNotification)
        await model.testNotification()
        pending?.resume()
        await testing.value
        precondition(notifications.count == 3 && !model.isTestingNotification)
        print("Notification checks passed")
    }

    static func liveProgressChecks() async throws {
        let suite = "geuntae-live-progress-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clockInRemindersEnabled")
        let vault = KeychainSession(service: suite, attendanceService: .flex)
        defer { try? vault.delete(); defaults.removePersistentDomain(forName: suite) }
        let now = try FlexDates.parse("2026-10-15T11:59:00")
        let rest = DateInterval(start: now.addingTimeInterval(60), end: now.addingTimeInterval(180))
        let clock = LiveWorkClock(start: now.addingTimeInterval(-120 * 60), completedMinutes: 0, rests: [rest], countsTowardTarget: true)
        var month = MonthlyReport(workedMinutes: 4200, outsideMinutes: 0, requiredMinutes: 9600,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: 13812)
        month.targetCreditedMinutes = 3770
        var record = DailyRecord(date: "2026-10-15", start: FlexDates.iso(clock.start),
            scheduledEnd: "2026-10-15T18:00:00+09:00", currentMinutes: 120)
        record.scheduledWorkday = true
        var fresh = AttendanceSnapshot(record: record, month: month, remainingWorkDays: 12, updatedAt: now)
        fresh.service = .flex
        fresh.todayCreditedMinutesInMonth = 0
        fresh.liveWorkClock = clock
        fresh.advanceLiveTime(to: now)
        var loads = 0
        var fail = false
        let model = WorkBarModel(flex: FlexBackend(vault: vault, snapshotLoader: { _ in
                loads += 1
                if fail { throw URLError(.notConnectedToInternet) }
                return fresh
            }), defaults: defaults, service: .flex)
        let cookie = HTTPCookie(properties: [.name: "JSESSIONID", .value: "test", .domain: "flex.team", .path: "/"])!
        await model.acceptCookies([cookie])
        precondition(model.loginCompleted && loads == 1)
        model.advanceLiveTime(to: now.addingTimeInterval(60))
        precondition(model.snapshot?.todayMinutes == 121 && model.snapshot?.attendanceNote?.hasPrefix("휴게 중") == true)
        model.advanceLiveTime(to: now.addingTimeInterval(120))
        precondition(model.snapshot?.todayMinutes == 121)
        model.advanceLiveTime(to: now.addingTimeInterval(240))
        precondition(model.snapshot?.todayMinutes == 122 && model.snapshot?.attendanceNote?.hasPrefix("근무 중") == true)
        precondition(model.snapshot?.minimumTodayMeter?.targetMinutes == 486)
        precondition(model.snapshot?.month.actualMinutes == 4200 && model.snapshot?.updatedAt == now && loads == 1)
        precondition(model.snapshot?.displayMonth.actualMinutes == 4322 && model.snapshot?.displayMonth.creditedMinutes == 3892)
        model.advanceLiveTime(to: now.addingTimeInterval(3600))
        precondition(model.snapshot?.todayMinutes == 122)
        fail = true
        _ = await model.refresh()
        model.advanceLiveTime(to: now.addingTimeInterval(300))
        precondition(!model.loginCompleted && model.snapshot?.todayMinutes == 122)
        fail = false
        _ = await model.refresh()
        model.advanceLiveTime(to: now.addingTimeInterval(300))
        precondition(model.snapshot?.todayMinutes == 123 && loads == 3)
        // Offline refreshes wait for the network instead of failing the connection.
        await model.networkChanged(false)
        let waiting = await model.refresh()
        precondition(!waiting && loads == 3 && model.loginCompleted && model.message == "네트워크 연결을 기다리는 중")
        await model.networkChanged(true)
        precondition(loads == 4 && model.loginCompleted && model.message == "방금 업데이트됨")
        for offset in [-3600.0, 3600.0] {
            fresh.serverClockOffset = offset
            _ = await model.refresh()
            let localNow = now.addingTimeInterval(-offset)
            model.advanceLiveTime(to: localNow.addingTimeInterval(240))
            precondition(model.snapshot?.todayMinutes == 122 && model.snapshot?.displayMonth.actualMinutes == 4322)
            model.advanceLiveTime(to: localNow.addingTimeInterval(3600))
            precondition(model.snapshot?.todayMinutes == 122)
        }
        await model.signOut()
        model.advanceLiveTime(to: now.addingTimeInterval(300))
        precondition(model.snapshot == nil)
    }

    static func flexWebLoginCookieChangeChecks() async throws {
        let suite = "geuntae-flex-web-login-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clockInRemindersEnabled")
        let vault = KeychainSession(service: suite, attendanceService: .flex)
        defer { try? vault.delete(); defaults.removePersistentDomain(forName: suite) }
        let webData = WKWebsiteDataStore.nonPersistent()
        let client = FlexClient()
        let month = MonthlyReport(workedMinutes: 120, outsideMinutes: 0, requiredMinutes: 480,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: nil)
        var snapshot = AttendanceSnapshot(record: nil, month: month, remainingWorkDays: 1, updatedAt: Date())
        snapshot.service = .flex
        var loads = 0
        let backend = FlexBackend(vault: vault, client: client, webDataStore: webData,
            snapshotLoader: { _ in
                loads += 1
                guard client.currentCookies().contains(where: { $0.name == "AID" && $0.value == "signed-in" }) else {
                    throw FlexError.authentication
                }
                return snapshot
            })
        let model = WorkBarModel(flex: backend, defaults: defaults, service: .flex)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webData
        let page = WKWebView(frame: .zero, configuration: configuration)
        let coordinator = LoginWebView.Coordinator(model: model) { _ in }
        page.navigationDelegate = coordinator
        coordinator.watch(page)
        defer { coordinator.stop(); page.stopLoading() }
        func cookie(_ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: "AID", .value: value, .domain: "flex.team", .path: "/"])!
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await webData.httpCookieStore.setCookie(cookie("before-login"))
        page.loadHTMLString("<html><body>flex login</body></html>", baseURL: URL(string: "https://flex.team/home")!)
        try await waitFor { loads == 1 && !model.isRefreshing }
        precondition(loads == 1 && !model.loginCompleted && model.snapshot == nil,
                     "The initial rejected session must not complete login")
        try await Task.sleep(nanoseconds: 3_200_000_000)
        precondition(loads == 1, "Unchanged cookies must not repeatedly call the attendance API")

        // SPA login replaces cookies without a new top-level navigation.
        await webData.httpCookieStore.setCookie(cookie("signed-in"))
        try await waitFor { model.loginCompleted }
        precondition(model.loginCompleted && loads == 2 && model.snapshot?.month.workedMinutes == 120,
                     "New login cookies must resume attendance loading without reopening the window")
        let saved = try vault.load()
        precondition(saved.contains { $0.name == "AID" && $0.value == "signed-in" })
        print("Flex WebKit login cookie-change checks passed")
    }

    static func flexWebLogoutChecks() async throws {
        let suite = "geuntae-flex-web-logout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clockInRemindersEnabled")
        let vault = KeychainSession(service: suite, attendanceService: .flex)
        defer { try? vault.delete(); defaults.removePersistentDomain(forName: suite) }
        let webData = WKWebsiteDataStore.nonPersistent()
        let month = MonthlyReport(workedMinutes: 0, outsideMinutes: 0, requiredMinutes: 480,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: nil)
        var snapshot = AttendanceSnapshot(record: nil, month: month, remainingWorkDays: 1, updatedAt: Date())
        snapshot.service = .flex
        let backend = FlexBackend(vault: vault, webDataStore: webData,
                                  snapshotLoader: { _ in snapshot })
        let model = WorkBarModel(flex: backend, defaults: defaults, service: .flex)
        let signedInSession = model.loginWebDataStore
        precondition(signedInSession === webData)
        let cookie = HTTPCookie(properties: [.name: "AID", .value: "logout-test", .domain: "flex.team", .path: "/"])!
        await webData.httpCookieStore.setCookie(cookie)
        await model.acceptCookies([cookie])
        precondition(model.loginCompleted)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webData
        let oldPage = WKWebView(frame: .zero, configuration: configuration)
        let oldCoordinator = LoginWebView.Coordinator(model: model) { _ in }
        oldCoordinator.watch(oldPage)
        defer { oldCoordinator.stop() }
        precondition(oldCoordinator.isActive)
        await model.signOut()
        let nextSession = model.loginWebDataStore
        precondition(nextSession !== signedInSession && !nextSession.isPersistent,
                     "Logging out must discard the signed-in page's browser session")
        precondition(!oldCoordinator.isActive && !model.hasSavedSession && model.loginCookies.isEmpty)
        let saved = try vault.load()
        precondition(saved.isEmpty)
        // A still-running old page must not sign the new login window back in.
        await webData.httpCookieStore.setCookie(cookie)
        model.beginSignIn()
        let newCookies = await nextSession.httpCookieStore.allCookies()
        precondition(newCookies.isEmpty && !oldCoordinator.isActive && !model.loginCompleted)
        await nextSession.httpCookieStore.setCookie(cookie)
        await model.acceptCookies([cookie])
        precondition(model.loginCompleted && model.hasSavedSession)
        precondition(model.loginWebDataStore === nextSession)
        let relaunched = WorkBarModel(flex: FlexBackend(vault: vault, snapshotLoader: { _ in snapshot }),
                                      defaults: defaults, service: .flex)
        precondition(!relaunched.loginWebDataStore.isPersistent && relaunched.hasSavedSession)
        precondition(relaunched.loginCookies.contains { $0.name == cookie.name })
        _ = await relaunched.refresh()
        let restoredCookies = await relaunched.loginWebDataStore.httpCookieStore.allCookies()
        precondition(relaunched.loginCompleted && restoredCookies.contains { $0.name == cookie.name })
        await model.signOut()
    }

    static func flexServiceChecks() async throws {
        let suite = "geuntae-flex-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clockInRemindersEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = KeychainSession(service: suite + ".wanted")
        let legacyItem = KeychainSession.Item(service: suite + ".legacy", account: "flex-credentials")
        let flexVault = KeychainSession(service: suite + ".web", attendanceService: .flex,
                                        legacyItemsToPurge: [legacyItem])
        defer { try? vault.delete(); try? flexVault.delete() }
        let cookie = HTTPCookie(properties: [.name: "wanted", .value: "test", .domain: "api.handyspace.ai", .path: "/"])!
        let flexCookie = HTTPCookie(properties: [.name: "JSESSIONID", .value: "test", .domain: "flex.team", .path: "/", .secure: "TRUE"])!
        _ = try vault.save([cookie])
        _ = try flexVault.save([flexCookie])
        let storage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: suite)
        defer { for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) } }
        let webData = WKWebsiteDataStore.nonPersistent()
        await webData.httpCookieStore.setCookie(cookie)
        await webData.httpCookieStore.setCookie(flexCookie)
        let month = MonthlyReport(workedMinutes: 0, outsideMinutes: 0, requiredMinutes: 480,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: nil)
        let wanted = AttendanceSnapshot(record: nil, month: month, remainingWorkDays: 1, updatedAt: Date())
        var flex = wanted
        flex.service = .flex
        flex.accountIdentifier = "company:user"
        var pending: CheckedContinuation<AttendanceSnapshot, Never>?
        var hold = false
        var error: Error?
        var saveError: Error?
        var wantedSaves = 0
        let model = WorkBarModel(
            wantedSpace: WantedSpaceBackend(vault: vault, client: AttendanceClient(cookies: storage),
                webDataStore: webData,
                snapshotLoader: { _ in wanted }, sessionSaver: { _ in wantedSaves += 1 }),
            flex: FlexBackend(vault: flexVault, webDataStore: webData, snapshotLoader: { _ in
                if let error { throw error }
                if hold { return await withCheckedContinuation { pending = $0 } }
                return flex
            }, sessionSaver: { cookies in
                if let saveError { throw saveError }
                _ = try flexVault.save(cookies)
            }),
            defaults: defaults)
        await model.selectService(.flex)
        precondition(model.snapshot?.service == .flex && model.loginCompleted && wantedSaves == 0)
        precondition(defaults.string(forKey: "attendanceService") == "flex")
        let savedWanted = try vault.load()
        precondition(!savedWanted.isEmpty)
        error = FlexError.permissionDenied
        _ = await model.refresh()
        precondition(model.snapshot?.service == .flex && model.hasSavedSession && model.message.contains("권한"))
        error = FlexError.invalidData("퇴근 기록에 대응하는 근무 내역이 없습니다.")
        _ = await model.refresh()
        precondition(model.hasSavedSession && model.snapshot?.service == .flex && !model.loginCompleted)
        precondition(model.loginFailureMessage?.contains("퇴근 기록에 대응하는 근무 내역이 없습니다") == true)
        let retainedSession = try flexVault.load()
        precondition(!retainedSession.isEmpty)
        error = nil
        hold = true
        let late = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        let switching = Task { await model.selectService(.wantedSpace) }
        while !model.isSigningOut { await Task.yield() }
        pending?.resume(returning: flex)
        let lateAccepted = await late.value
        await switching.value
        precondition(!lateAccepted && model.snapshot?.service == .wantedSpace && wantedSaves == 1)
        let savedFlex = try flexVault.load()
        precondition(savedFlex.count == 1)
        hold = false
        await model.selectService(.flex)
        await model.signOut()
        let removedFlex = try flexVault.load(), retainedWanted = try vault.load()
        let browserCookies = await webData.httpCookieStore.allCookies()
        precondition(removedFlex.isEmpty && !retainedWanted.isEmpty && model.snapshot == nil)
        precondition(!browserCookies.contains { SavedCookie($0).belongsTo(.flex) })
        precondition(browserCookies.contains { SavedCookie($0).belongsTo(.wantedSpace) })
        await model.selectService(.wantedSpace)
        precondition(model.loginCompleted && model.snapshot?.service == .wantedSpace)
        await model.selectService(.flex)
        model.beginSignIn()
        let legacyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyItem.service, kSecAttrAccount as String: "flex-credentials"]
        var oldCredentials = legacyQuery
        oldCredentials[kSecValueData as String] = Data("legacy-test-credentials".utf8)
        precondition(SecItemAdd(oldCredentials as CFDictionary, nil) == errSecSuccess)
        saveError = KeychainError(-25291)
        await model.acceptCookies([flexCookie])
        precondition(!model.loginCompleted && model.snapshot == nil && model.loginFailureMessage?.contains("키체인") == true)
        precondition(SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecSuccess)
        saveError = nil
        await model.acceptCookies([flexCookie])
        precondition(model.loginCompleted)
        precondition(SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecItemNotFound)
        error = FlexError.authentication
        _ = await model.refresh()
        let expired = try flexVault.load()
        precondition(expired.isEmpty && !model.loginCompleted && !model.hasSavedSession && model.snapshot == nil)

        // Keep the initial login's cookies too when a later attendance request fails.
        error = URLError(.notConnectedToInternet)
        model.beginSignIn()
        await model.acceptCookies([flexCookie])
        let retryable = try flexVault.load()
        precondition(!retryable.isEmpty && !model.loginCompleted)
    }
    static func legacyPurgeFailureChecks() async throws {
        let suite = "geuntae-legacy-purge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clockInRemindersEnabled")
        let item = KeychainSession.Item(service: suite + ".legacy", account: "flex-credentials")
        let vault = KeychainSession(service: suite + ".web", attendanceService: .flex,
                                   legacyItemsToPurge: [item],
                                   deleteItem: { _ in throw KeychainError(-25291) })
        defer { try? vault.delete() }
        let month = MonthlyReport(workedMinutes: 0, outsideMinutes: 0, requiredMinutes: 480,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: nil)
        var snapshot = AttendanceSnapshot(record: nil, month: month, remainingWorkDays: 1, updatedAt: Date())
        snapshot.service = .flex
        let model = WorkBarModel(flex: FlexBackend(vault: vault, snapshotLoader: { _ in snapshot }),
            defaults: defaults, service: .flex)
        let refreshed = await model.refresh()
        precondition(refreshed && model.snapshot?.service == .flex && model.loginCompleted)
        let signedInStore = model.loginWebDataStore
        let cookie = HTTPCookie(properties: [.name: "AID", .value: "purge-failure-test", .domain: "flex.team", .path: "/"])!
        await signedInStore.httpCookieStore.setCookie(cookie)
        await model.acceptCookies([cookie])
        let savedCookies = model.loginCookies
        await model.signOut()
        precondition(model.message == "Keychain 삭제 실패")
        precondition(model.loginWebDataStore !== signedInStore && model.loginCookies.isEmpty,
                     "A Keychain deletion error must not leave the web page signed in")
        precondition(model.loginFailureMessage?.contains("키체인") == true)
        let browserCookies = await signedInStore.httpCookieStore.allCookies()
        precondition(!browserCookies.contains { SavedCookie($0).belongsTo(.flex) })
        let resaved = try vault.save(savedCookies)
        precondition(resaved, "A partial logout must not skip saving the next login's unchanged cookies")
        let restored = try vault.load()
        precondition(restored.contains { $0.name == cookie.name })
    }

}
