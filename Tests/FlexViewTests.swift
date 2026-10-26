import AppKit
import SwiftUI
import Vision

@main
@MainActor
struct FlexViewTests {
    static func main() async throws {
        let suite = "flex-view-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let vault = KeychainSession(service: suite + ".web", attendanceService: .flex)
        defer { try? vault.delete() }
        let now = try FlexDates.parse("2026-10-07T15:00:00")
        var report = MonthlyReport(workedMinutes: 4200, outsideMinutes: 0, requiredMinutes: 9600,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: 13812)
        report.targetCreditedMinutes = 3770
        var snapshot = AttendanceSnapshot(record: DailyRecord(date: "2026-10-07", start: "2026-10-07T09:00:00+09:00",
            scheduledEnd: "2026-10-07T18:00:00+09:00", currentMinutes: 300, holidayStatus: "WEEKDAY_WORKING_ON_NONE_NONE"),
            month: report, remainingWorkDays: 15, updatedAt: now)
        snapshot.service = .flex
        snapshot.accountIdentifier = "A001"
        snapshot.isEstimated = true
        snapshot.liveWorkClock = LiveWorkClock(start: try FlexDates.parse("2026-10-07T09:00:00"), completedMinutes: 0,
            rests: [DateInterval(start: try FlexDates.parse("2026-10-07T12:00:00"), end: try FlexDates.parse("2026-10-07T13:00:00"))],
            countsTowardTarget: true)
        snapshot.advanceLiveTime(to: now)
        snapshot.todayCreditedMinutesInMonth = 0
        snapshot.compensationEstimate = CompensationEstimate(month: report, days: [], holidays: [:])
        defaults.set(false, forKey: "clockInRemindersEnabled")
        var fetchError: Error?
        let model = WorkBarModel(flex: FlexBackend(vault: vault, snapshotLoader: { _ in
            if let fetchError { throw fetchError }
            return snapshot
        }),
            defaults: defaults, service: .flex)
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("geuntae-flex-views")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        func render<V: View>(_ content: V, _ name: String, width: CGFloat, height: CGFloat) throws -> String {
            let view = NSHostingView(rootView: content.environment(\.colorScheme, .light).background(Color.white))
            view.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["ko-KR", "en-US"]
            try VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
            window.close()
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined().filter { !$0.isWhitespace }
        }
        let connectionText = try render(LoginWindow(model: model), "connection", width: 760, height: 650)
        precondition(connectionText.contains("flex") && connectionText.contains("로그인"), connectionText)
        precondition(!connectionText.contains("ClientSecret") && !connectionText.contains("본인사번"))
        let cookie = HTTPCookie(properties: [.name: "JSESSIONID", .value: "view-test", .domain: "flex.team", .path: "/"])!
        model.beginSignIn()
        await model.acceptCookies([cookie])
        precondition(model.loginCompleted)
        let menuText = try render(WorkMenu(model: model), "menu", width: 728, height: 680)
        precondition(menuText.contains("근무중") && !menuText.contains("서버기록기준") && !menuText.contains("추정"), menuText)
        precondition(menuText.contains("누적75시간0분"), menuText)
        precondition(menuText.contains("15일") && menuText.contains("6.1시간") && menuText.contains("63%달성"), menuText)
        precondition(menuText.contains("92시간10분") && menuText.contains("230시간12분"), menuText)
        model.advanceLiveTime(to: now.addingTimeInterval(60))
        let nextMinute = try render(WorkMenu(model: model), "menu-next-minute", width: 728, height: 680)
        precondition(nextMinute.contains("누적75시간1분") && nextMinute.contains("92시간9분"), nextMinute)
        let updater = AppUpdater(appURL: output.appendingPathComponent("missing.app"), defaults: defaults,
                                 logURL: output.appendingPathComponent("update.log"))
        let optionsText = try render(WorkOptionsWindow(model: model, onboarding: OnboardingState(defaults: defaults), updater: updater),
                                     "options", width: 440, height: 640)
        precondition(optionsText.contains("flex연결됨"), optionsText)
        fetchError = FlexError.invalidData("퇴근 기록에 대응하는 근무 내역이 없습니다.")
        _ = await model.refresh()
        precondition(model.hasSavedSession && !model.loginCompleted)
        let failedMenu = try render(WorkMenu(model: model), "menu-fetch-failed", width: 728, height: 760)
        precondition(failedMenu.contains("퇴근기록에대응하는근무내역이없습니다"), failedMenu)
        let failedOptions = try render(WorkOptionsWindow(model: model, onboarding: OnboardingState(defaults: defaults), updater: updater),
                                       "options-fetch-failed", width: 440, height: 640)
        precondition(failedOptions.contains("퇴근기록에대응하는근무내역이없습니다") && failedOptions.contains("다시조회") && !failedOptions.contains("flex연결됨"), failedOptions)
        fetchError = nil
        _ = await model.refresh()
        let recoveredOptions = try render(WorkOptionsWindow(model: model, onboarding: OnboardingState(defaults: defaults), updater: updater),
                                          "options-fetch-recovered", width: 440, height: 640)
        precondition(recoveredOptions.contains("flex연결됨") && !recoveredOptions.contains("근태정보확인불가"), recoveredOptions)
        let onboarding = OnboardingState(defaults: defaults)
        onboarding.show(); onboarding.showSignIn()
        model.beginSignIn()
        _ = try render(OnboardingWindow(model: model, onboarding: onboarding), "onboarding", width: 920, height: 760)
        for _ in 0..<3 { onboarding.next(isSignedIn: true) }
        _ = try render(OnboardingWindow(model: model, onboarding: onboarding), "onboarding-calendar", width: 920, height: 760)
        print("Flex view checks passed: \(output.path)")
    }
}
