import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    @Published var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: "automaticUpdateChecks")
            if automaticChecks { Task { await check() } }
        }
    }
    @Published private(set) var message = "업데이트 확인 전"
    @Published private(set) var availableRevision: String?
    @Published private(set) var availableCommits: [String] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var installFailed = false
    /// Current install step (1-based) from the scripts' `progress:` lines; 0 before the first step.
    @Published private(set) var installStep = 0
    nonisolated static let installSteps = [("download", "새 버전 받는 중"), ("build", "빌드 중"), ("install", "설치 중"), ("restart", "재시작 중")]
    let logURL: URL

    private let appURL: URL
    private let defaults: UserDefaults
    private let confirmInstall: @MainActor (String, [String]) async -> Bool
    private var promptsForInstall = false
    private var timer: Timer?
    private var installer: Process?
    private var scriptURL: URL { appURL.appendingPathComponent("Contents/Resources/update.sh") }

    init(appURL: URL = Bundle.main.bundleURL, defaults: UserDefaults = .standard, logURL: URL? = nil,
         confirmInstall: @escaping @MainActor (String, [String]) async -> Bool = AppUpdater.askToInstall) {
        self.appURL = appURL
        self.defaults = defaults
        self.logURL = logURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeuntaeBar/update.log")
        self.confirmInstall = confirmInstall
        automaticChecks = defaults.object(forKey: "automaticUpdateChecks") as? Bool ?? true
    }

    func start() {
        guard timer == nil else { return }
        promptsForInstall = true
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(force: false) }
        }
    }

    func check(force: Bool = true) async {
        guard !isChecking, !isInstalling else { return }
        if !force {
            guard automaticChecks else { return }
            let lastCheck = defaults.object(forKey: "lastAppUpdateCheck") as? Date ?? .distantPast
            guard Date().timeIntervalSince(lastCheck) >= 86400 else { return }
        }
        isChecking = true
        availableRevision = nil
        availableCommits = []
        message = "새 버전 확인 중…"
        defaults.set(Date(), forKey: "lastAppUpdateCheck")
        defer { isChecking = false }
        do {
            let script = scriptURL
            let app = appURL
            let result = try await Task.detached(priority: .utility) {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [script.path, "check", app.path]
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }.value
            guard result.0 == 0 else { throw CocoaError(.fileReadUnknown) }
            let lines = result.1.components(separatedBy: "\n")
            let status = lines[0]
            switch status {
            case "current":
                message = "최신 버전입니다"
            case "local":
                message = "로컬 변경이 있는 빌드는 수동으로 업데이트해주세요"
            default:
                guard status.hasPrefix("available:") else { throw CocoaError(.fileReadCorruptFile) }
                let revision = String(status.dropFirst("available:".count))
                guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                      lines.count > 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                availableRevision = revision
                availableCommits = Array(lines.dropFirst())
                message = "새 버전을 설치할 수 있습니다"
                // After this check returns, so install() is not blocked by isChecking.
                if promptsForInstall { Task { await promptToInstall(revision: revision) } }
            }
        } catch {
            message = "업데이트를 확인하지 못했어요. 연결을 확인하고 다시 시도해주세요."
        }
    }

    func install() {
        guard let revision = availableRevision, !isChecking, !isInstalling else { return }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try Data().write(to: logURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            let log = try FileHandle(forWritingTo: logURL)
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path, "install", appURL.path, revision]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            try? output.fileHandleForWriting.close()
            installer = process
            isInstalling = true
            installFailed = false
            installStep = 0
            message = "업데이트를 시작하고 있어요. 완료되면 앱이 재시작됩니다."
            Task.detached { [weak self] in
                // Read to EOF before reporting the result so the log is complete.
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        log.write(Data((line + "\n").utf8))
                        guard let step = Self.installSteps.firstIndex(where: { "progress:" + $0.0 == line }) else { continue }
                        await self?.showInstallStep(step + 1)
                    }
                } catch {}
                try? log.close()
                process.waitUntilExit()
                await self?.finishInstall(status: process.terminationStatus)
            }
        } catch {
            installFailed = true
            message = "업데이트를 시작하지 못했어요: \(error.localizedDescription)"
        }
    }

    private func showInstallStep(_ step: Int) {
        installStep = step
        message = "업데이트 \(step)/\(Self.installSteps.count) · \(Self.installSteps[step - 1].1)…"
    }

    private func finishInstall(status: Int32) async {
        installer = nil
        isInstalling = false
        installStep = 0
        if status != 0 {
            installFailed = true
            message = "업데이트에 실패했어요. 로그를 확인한 뒤 다시 시도해주세요."
        } else {
            await check()
        }
    }

    /// Asks once per revision; declining leaves the install button in the options window.
    private func promptToInstall(revision: String) async {
        guard !isChecking, availableRevision == revision else { return }
        guard defaults.string(forKey: "lastPromptedAppRevision") != revision else { return }
        defaults.set(revision, forKey: "lastPromptedAppRevision")
        guard await confirmInstall(revision, availableCommits), availableRevision == revision else { return }
        install()
        // Accepted from the alert: open the options window so the progress is visible.
        NotificationCenter.default.post(name: Self.showProgressNotification, object: nil)
    }
    static let showProgressNotification = Notification.Name("GeuntaeBarShowUpdateProgress")

    static func askToInstall(_ revision: String, commits: [String]) async -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Geuntae bar 새 버전이 있어요"
        alert.informativeText = "지금 업데이트할까요? 새 버전을 빌드한 뒤 앱이 재시작됩니다."
        let changes = NSHostingView(rootView: UpdateCommitList(commits: commits))
        changes.frame = NSRect(x: 0, y: 0, width: 380, height: 150)
        alert.accessoryView = changes
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "나중에")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct UpdateCommitList: View {
    let commits: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("포함된 커밋 \(commits.count)개").font(.caption).bold()
            ScrollView {
                Text(commits.joined(separator: "\n"))
                    .font(.caption)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }
}
