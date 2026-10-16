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
        snapshot.customHolidayDeduction = CustomHolidayDeduction(dates: ["2026-10-14", "2026-10-28"], minutes: 960,
            maximumMinutes: 960, flexRequiredMinutes: 10560, flexMaximumMinutes: 14772)
        defaults.set(false, forKey: "clockInRemindersEnabled")
        let model = WorkBarModel(flex: FlexBackend(vault: vault, snapshotLoader: { _, _ in snapshot }),
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
        let menuText = try render(WorkMenu(model: model), "menu", width: 340, height: 680)
        precondition(menuText.contains("근무중") && !menuText.contains("서버기록기준") && !menuText.contains("추정"), menuText)
        precondition(menuText.contains("누적75시간0분") && menuText.contains("근무일15일"), menuText)
        precondition(menuText.contains("필수근무시간-92시간10분(하루평균6시간9분)"), menuText)
        precondition(menuText.contains("92시간10분") && menuText.contains("230시간12분"), menuText)
        precondition(menuText.contains("휴일10/14,10/28") && menuText.contains("16시간0분"), menuText)
        precondition(!menuText.contains("설정기준"), menuText)
        model.advanceLiveTime(to: now.addingTimeInterval(60))
        let nextMinute = try render(WorkMenu(model: model), "menu-next-minute", width: 340, height: 680)
        precondition(nextMinute.contains("누적75시간1분") && nextMinute.contains("92시간9분"), nextMinute)
        model.customHoliday = CustomHolidayRule(weekday: 4, ordinals: [2, 4])
        let updater = AppUpdater(appURL: output.appendingPathComponent("missing.app"), defaults: defaults,
                                 logURL: output.appendingPathComponent("update.log"))
        let optionsText = try render(WorkOptionsWindow(model: model, onboarding: OnboardingState(defaults: defaults), updater: updater),
                                     "options", width: 440, height: 640)
        // The preview bar sits right under the deduction checkboxes.
        precondition(optionsText.contains("차감대상") && optionsText.contains("필수시간대비42%"), optionsText)
        let onboarding = OnboardingState(defaults: defaults)
        onboarding.show(); onboarding.showSignIn()
        model.beginSignIn()
        _ = try render(OnboardingWindow(model: model, onboarding: onboarding), "onboarding", width: 920, height: 760)
        for _ in 0..<3 { onboarding.next(isSignedIn: true) }
        let holidayStep = try render(OnboardingWindow(model: model, onboarding: onboarding), "onboarding-holiday", width: 920, height: 760)
        precondition(holidayStep.contains("정기휴무설정") && holidayStep.contains("차감대상"), holidayStep)
        print("Flex view checks passed: \(output.path)")
    }
}
