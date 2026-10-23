import AppKit
import BarPilotCore

@MainActor
final class ProMediaTransport {
    var onSnapshot: ((ProMediaSnapshot?) -> Void)?
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var output: FileHandle?
    private var intentionallyStopped = false
    private let commands = DispatchQueue(label: "local.pakwingho.barpilot.media-commands")
    private var framework: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework")
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }
    private var script: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ProMedia/mediaremote-adapter.pl")
        return bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    var isAvailable: Bool { framework != nil && script != nil }
    var isRunning: Bool { process?.isRunning == true }
    func start() {
        guard process == nil else { return }
        guard let framework, let script else { onFailure?("系統播放接駁資源未包含在 App。可選 Music / Spotify 控制。"); return }
        intentionallyStopped = false
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream", "--no-diff", "--debounce=150"]
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe
        let buffer = ProMediaLineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let lines = buffer.append(data)
            Task { @MainActor in
                guard let self, self.process === process else { return }
                for line in lines {
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        object["payload"] is [String: Any] else { continue }
                    self.onSnapshot?(ProMediaSnapshot.parse(line))
                }
            }
        }
        process.terminationHandler = { [weak self] completed in
            Task { @MainActor in
                guard let self, self.process === completed else { return }
                self.output?.readabilityHandler = nil; self.process = nil; self.output = nil
                if !self.intentionallyStopped { self.onFailure?("系統播放接駁已停止。可重新啟用或選 Music / Spotify。"); }
            }
        }
        do { try process.run(); self.process = process; output = pipe.fileHandleForReading }
        catch { onFailure?(error.localizedDescription) }
    }
    func stop() {
        intentionallyStopped = true; output?.readabilityHandler = nil; output = nil
        process?.terminate(); process = nil
    }
    func send(_ arguments: [String]) {
        guard let framework, let script, process?.isRunning == true else { return }
        commands.async {
            let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            command.arguments = [script.path, framework.path] + arguments
            command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
            do { try command.run(); command.waitUntilExit() } catch {}
        }
    }
}

private final class ProMediaLineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ incoming: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        data.append(incoming)
        guard data.count <= 6 * 1024 * 1024 else { data.removeAll(); return [] }
        var result: [Data] = []
        while let newline = data.firstIndex(of: 10) {
            result.append(data.subdata(in: data.startIndex..<newline)); data.removeSubrange(data.startIndex...newline)
        }
        return result
    }
}
