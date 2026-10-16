import AppKit
import SwiftUI
import Vision

@main
struct UpdaterTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("geuntae-updater-\(UUID().uuidString)")
        let resources = directory.appendingPathComponent("Test.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "geuntae-updater-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "clockInRemindersEnabled")
        let app = directory.appendingPathComponent("Test.app")
        let script = resources.appendingPathComponent("update.sh")
        try """
        #!/bin/sh
        cd "$(dirname "$0")"
        if [ "$1" = check ]; then
            echo check >> checks
            cat response
            exit "$(cat status)"
        fi
        echo 'Test install failure'
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        func response(_ value: String, status: Int = 0) throws {
            try value.write(to: resources.appendingPathComponent("response"), atomically: true, encoding: .utf8)
            try String(status).write(to: resources.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        }
        let revision = String(repeating: "a", count: 40)
        let updater = AppUpdater(appURL: app, defaults: defaults,
                                 logURL: directory.appendingPathComponent("update.log"))
        precondition(updater.automaticChecks)
        try response("available:\(revision)")
        await updater.check(force: false)
        precondition(updater.availableRevision == revision && !updater.isChecking)
        await updater.check(force: false)
        let checks = try String(contentsOf: resources.appendingPathComponent("checks"), encoding: .utf8)
        precondition(checks == "check\n")

        let record = DailyRecord(date: "2026-10-07", scheduledStart: "2026-10-07T09:00:00+09:00",
            scheduledEnd: "2026-10-07T18:00:00+09:00", holidayStatus: "WEEKDAY_WORKING_ON_NONE_NONE")
        let month = MonthlyReport(workedMinutes: 0, outsideMinutes: 0, requiredMinutes: 480,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: nil)
        var snapshot = AttendanceSnapshot(record: record, month: month, remainingWorkDays: 1, updatedAt: Date())
        snapshot.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let model = WorkBarModel(wantedSpace: WantedSpaceBackend(vault: KeychainSession(service: suite),
            snapshotLoader: { _ in snapshot }, sessionSaver: { _ in }), defaults: defaults)
        let refreshed = await model.refresh()
        precondition(refreshed)
        let onboarding = OnboardingState(defaults: defaults)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: WorkOptionsWindow(model: model, onboarding: onboarding, updater: updater)
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.close()
        let image = bitmap.cgImage!
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/geuntae-bar-updater-options.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().filter { !$0.isWhitespace }
        precondition(text.contains("새버전자동확인") && text.contains("업데이트설치") && text.contains("종료"))
        precondition(text.contains("알림테스트"))
        let reminderTime = snapshot.clockInReminderTime(mode: model.reminderMode, delayMinutes: model.reminderDelayMinutes)
        precondition(text.contains("기준시각\(model.reminderDelayMinutes)분후(\(reminderTime))"))

        updater.install()
        precondition(updater.isInstalling)
        for _ in 0..<200 where updater.isInstalling { try await Task.sleep(for: .milliseconds(10)) }
        precondition(updater.installFailed && !updater.isInstalling)
        let installLog = try String(contentsOf: updater.logURL, encoding: .utf8)
        precondition(installLog.contains("Test install failure"))

        try response("current")
        await updater.check()
        precondition(updater.availableRevision == nil && updater.message == "최신 버전입니다")
        try response("local")
        await updater.check()
        precondition(updater.availableRevision == nil && updater.message.contains("수동"))
        for (body, status) in [("network failure", 1), ("available:not-a-commit", 0)] {
            try response(body, status: status)
            await updater.check()
            precondition(!updater.isChecking && updater.message.contains("확인하지 못했어요"))
        }

        updater.automaticChecks = false
        defaults.removeObject(forKey: "lastAppUpdateCheck")
        try response("current")
        await updater.check(force: false)
        precondition(defaults.object(forKey: "lastAppUpdateCheck") == nil)
        await updater.check()
        precondition(updater.message == "최신 버전입니다")
        let reopened = AppUpdater(appURL: app, defaults: defaults)
        precondition(!reopened.automaticChecks)

        // A started updater asks once per new revision and installs only when accepted.
        var prompts: [String] = []
        var accept = false
        let prompting = AppUpdater(appURL: app, defaults: defaults, logURL: directory.appendingPathComponent("prompt.log"),
                                   confirmInstall: { prompts.append($0); return accept })
        prompting.start()
        try response("available:\(revision)")
        await prompting.check()
        for _ in 0..<100 where prompts.isEmpty { await Task.yield() }
        precondition(prompts == [revision] && !prompting.isInstalling)
        await prompting.check()
        for _ in 0..<100 { await Task.yield() }
        precondition(prompts == [revision])
        let next = String(repeating: "b", count: 40)
        accept = true
        try response("available:\(next)")
        await prompting.check()
        for _ in 0..<100 where !prompting.isInstalling { await Task.yield() }
        precondition(prompts == [revision, next] && prompting.isInstalling)
        for _ in 0..<200 where prompting.isInstalling { try await Task.sleep(for: .milliseconds(10)) }
        precondition(prompting.installFailed)
        print("App update checks passed")
    }
}
