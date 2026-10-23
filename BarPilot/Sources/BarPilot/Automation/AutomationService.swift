import AppKit
import BarPilotCore
import Combine

@MainActor
final class ProAutomationService: ObservableObject {
    @Published private(set) var enabled = false
    @Published var rules: [ProAutomationRule] = [] { didSet { persist() } }
    @Published var widgets: [ProActionWidget] = [] { didSet { persist() } }
    @Published private(set) var status = "未啟用"
    @Published private(set) var running = false
    private let file: URL
    private let applyPreset: (UUID) -> Void
    private let showShelf: () -> Void
    private var gate = AutomationGate()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var loading = false
    private var pending: [QueuedAutomationJob] = []
    private var command: ProRunningCommand?
    private struct Document: Codable { let rules: [ProAutomationRule]; let widgets: [ProActionWidget] }
    init(directory: URL, applyPreset: @escaping (UUID) -> Void, showShelf: @escaping () -> Void) {
        file = directory.appendingPathComponent("automation.json"); self.applyPreset = applyPreset; self.showShelf = showShelf
        loading = true
        do {
            if let document = try ProStorage.read(Document.self, at: file, maxBytes: 1024 * 1024) {
                rules = document.rules; widgets = document.widgets
            }
        } catch { status = error.localizedDescription }
        loading = false
    }
    func setEnabled(_ value: Bool) {
        enabled = value; timer?.invalidate(); timer = nil; gate.reset(); pending.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        guard value else { command?.cancel(); status = "未啟用"; return }
        status = "等待條件；規則只在條件由不符合變為符合時執行。"
        let apps = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        let displays = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        observers = [apps, displays]
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        timer?.tolerance = 5
        evaluate()
    }
    func evaluate() {
        guard enabled, !running else { return }
        let matches = gate.actions(rules: rules, context: currentContext(), now: Date())
        pending.append(contentsOf: matches.compactMap { id, action in
            guard let rule = rules.first(where: { $0.id == id }), rule.action == action else { return nil }
            return QueuedAutomationJob(rule: rule)
        })
        runNext()
    }
    private func currentContext() -> AutomationContext {
        let battery = rules.contains { $0.conditions.contains { if case .batteryBelow = $0 { return true }; return false } }
            ? ProSystemReader.battery() : ProBatteryState()
        return AutomationContext(frontApplication: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            displayCount: NSScreen.screens.count, batteryPercent: battery.percent, onBattery: !battery.pluggedIn, date: Date())
    }
    func run(_ action: ProAction) {
        guard enabled, !running else { return }
        switch action {
        case .preset(let id): applyPreset(id); status = "已要求套用預設"
        case .showShelf: showShelf(); status = "已開啟工作架"
        case .shortcut(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else {
                status = "請填寫現有捷徑名稱。"; return
            }
            execute(executable: "/usr/bin/shortcuts", arguments: ["run", name])
        case .localScript(let path, let arguments):
            guard path.hasPrefix("/"), arguments.count <= 50, arguments.allSatisfy({ $0.count <= 4096 }),
                FileManager.default.fileExists(atPath: path) else { status = "已設定的本機腳本不存在。"; return }
            switch URL(fileURLWithPath: path).pathExtension.lowercased() {
            case "sh": execute(executable: "/bin/bash", arguments: [path] + arguments)
            case "zsh": execute(executable: "/bin/zsh", arguments: [path] + arguments)
            case "py": execute(executable: "/usr/bin/env", arguments: ["python3", path] + arguments)
            case "js": execute(executable: "/usr/bin/env", arguments: ["node", path] + arguments)
            default: status = "只支援你選取的 .sh、.zsh、.py 或 .js 腳本。"
            }
        }
    }
    private func execute(executable: String, arguments: [String]) {
        running = true; status = "執行中…"
        let command = ProRunningCommand(); self.command = command
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) { () -> String in
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                var childEnvironment = ProcessInfo.processInfo.environment
                let existingPaths = (childEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
                var seenPaths = Set<String>()
                childEnvironment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"] + existingPaths)
                    .filter { !$0.isEmpty && seenPaths.insert($0).inserted }.joined(separator: ":")
                process.environment = childEnvironment
                // Never ingest command output into a widget, where it might contain secrets.
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                do {
                    guard try command.begin(process) else { return "已停止" }
                    let deadline = Date().addingTimeInterval(60)
                    while process.isRunning && Date() < deadline && !command.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                    if command.isCancelled { return "已停止" }
                    if process.isRunning { process.terminate(); return "已超過 60 秒；停止腳本。" }
                    return process.terminationStatus == 0 ? "已完成" : "執行失敗（結束碼 \(process.terminationStatus)）"
                } catch { return error.localizedDescription }
            }.value
            running = false; self.command = nil
            if enabled { status = result; runNext() }
        }
    }
    private func runNext() {
        guard enabled, !running else { return }
        while !pending.isEmpty {
            let job = pending.removeFirst()
            guard job.isEligible(rules: rules, context: currentContext()) else { continue }
            run(job.expectedAction)
            if running { return }
        }
    }
    private func persist() {
        guard !loading else { return }
        do { try ProStorage.write(Document(rules: rules, widgets: widgets), to: file) }
        catch { status = error.localizedDescription }
    }
}

private final class ProRunningCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func begin(_ process: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process; try process.run(); return true
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
