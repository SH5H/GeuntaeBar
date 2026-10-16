import AppKit
import Combine
import Foundation

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
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var installFailed = false
    let logURL: URL

    private let appURL: URL
    private let defaults: UserDefaults
    private let confirmInstall: @MainActor (String) async -> Bool
    private var promptsForInstall = false
    private var timer: Timer?
    private var installer: Process?
    private var scriptURL: URL { appURL.appendingPathComponent("Contents/Resources/update.sh") }

    init(appURL: URL = Bundle.main.bundleURL, defaults: UserDefaults = .standard, logURL: URL? = nil,
         confirmInstall: @escaping @MainActor (String) async -> Bool = AppUpdater.askToInstall) {
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
            switch result.1 {
            case "current":
                availableRevision = nil
                message = "최신 버전입니다"
            case "local":
                availableRevision = nil
                message = "로컬 변경이 있는 빌드는 수동으로 업데이트해주세요"
            default:
                guard result.1.hasPrefix("available:") else { throw CocoaError(.fileReadCorruptFile) }
                let revision = String(result.1.dropFirst("available:".count))
                guard revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                availableRevision = revision
                message = "새 버전을 설치할 수 있습니다"
                // After this check returns, so install() is not blocked by isChecking.
                if promptsForInstall { Task { await promptToInstall(revision: revision) } }
            }
        } catch {
            message = "업데이트를 확인하지 못했어요. 연결을 확인하고 다시 시도해주세요."
        }
    }

    func install() {
        guard availableRevision != nil, !isChecking, !isInstalling else { return }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try Data().write(to: logURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path, "install", appURL.path]
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self else { return }
                    self.installer = nil
                    self.isInstalling = false
                    if process.terminationStatus != 0 {
                        self.installFailed = true
                        self.message = "업데이트에 실패했어요. 로그를 확인한 뒤 다시 시도해주세요."
                    } else {
                        await self.check()
                    }
                }
            }
            try process.run()
            installer = process
            isInstalling = true
            installFailed = false
            message = "새 버전을 준비하고 있어요. 완료되면 앱이 재시작됩니다."
        } catch {
            installFailed = true
            message = "업데이트를 시작하지 못했어요: \(error.localizedDescription)"
        }
    }

    /// Asks once per revision; declining leaves the install button in the options window.
    private func promptToInstall(revision: String) async {
        guard defaults.string(forKey: "lastPromptedAppRevision") != revision else { return }
        defaults.set(revision, forKey: "lastPromptedAppRevision")
        if await confirmInstall(revision) { install() }
    }

    static func askToInstall(_ revision: String) async -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Geuntae bar 새 버전이 있어요"
        alert.informativeText = "지금 업데이트할까요? 새 버전을 빌드한 뒤 앱이 재시작됩니다."
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "나중에")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
