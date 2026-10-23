import BarPilotCore
import Combine
import Foundation

struct ProAgentActivity: Identifiable {
    let id: String
    let name: String
    let latestWrite: Date?
    let localSessionFiles: Int
    let quota: AgentSnapshotReader.Snapshot?
}

@MainActor
final class AgentActivityService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var agents: [ProAgentActivity] = []
    @Published private(set) var refreshing = false
    private let home: URL
    private var timer: Timer?
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    func setEnabled(_ value: Bool) {
        enabled = value; timer?.invalidate(); timer = nil
        guard value else { agents = []; return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 10
    }
    func refresh() {
        guard enabled, !refreshing else { return }
        refreshing = true
        let home = self.home
        Task { @MainActor in
            let snapshots = await Task.detached(priority: .utility) { Self.readLocalMetadata(home: home) }.value
            refreshing = false
            if enabled { agents = snapshots }
        }
    }
    nonisolated private static func readLocalMetadata(home: URL) -> [ProAgentActivity] {
        let bridge = home.appendingPathComponent("Library/Application Support/NotchHub/usage-snapshot.json")
        let size = (try? bridge.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let data = size > 0 && size <= 1024 * 1024 ? (try? Data(contentsOf: bridge)) : nil
        let quotas = data.map { AgentSnapshotReader.read($0, now: Date()) } ?? []
        return [("codex", "Codex", ".codex/sessions"), ("claude", "Claude Code", ".claude/projects")].map { provider, name, directory in
            var latest: Date?; var count = 0; var examined = 0
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .isSymbolicLinkKey]
            let enumerator = FileManager.default.enumerator(at: home.appendingPathComponent(directory),
                includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL, examined < 5000 {
                examined += 1
                guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                count += 1
                if let date = values.contentModificationDate, latest == nil || date > latest! { latest = date }
            }
            return ProAgentActivity(id: provider, name: name, latestWrite: latest, localSessionFiles: count,
                quota: quotas.first { $0.provider == provider })
        }
    }
}
