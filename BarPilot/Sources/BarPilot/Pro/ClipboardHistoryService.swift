import AppKit
import BarPilotCore
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistoryService: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var enabled = false
    @Published var message: String?
    var days = 7
    var limit = 100
    var previousApplication: NSRunningApplication?
    private let file: URL
    private var timer: Timer?
    private var changeCount = -1
    private var lastPruned = Date.distantPast
    init(directory: URL) { file = directory.appendingPathComponent("clipboard-history.json") }

    func setEnabled(_ value: Bool) {
        timer?.invalidate(); timer = nil; enabled = value
        guard value else { entries = []; return }
        do {
            // Base64 in JSON adds one third to the 20 MB payload cap.
            entries = ClipboardHistoryPolicy.prune(try ProStorage.read([ClipboardEntry].self, at: file, maxBytes: 32 * 1024 * 1024) ?? [],
                now: Date(), days: days, limit: limit)
            try save()
            lastPruned = Date()
        } catch { message = error.localizedDescription }
        // Never collect the clipboard that predates the user's enable action.
        changeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 0.25
    }

    func poll() {
        guard enabled else { return }
        if Date().timeIntervalSince(lastPruned) >= 300 {
            let retained = ClipboardHistoryPolicy.prune(entries, now: Date(), days: days, limit: limit)
            if retained.map(\.id) != entries.map(\.id) { entries = retained; persist() }
            lastPruned = Date()
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard ClipboardHistoryPolicy.mayCollect(types: types) else { return }
        let payload: (ClipboardKind, Data, String)?
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            payload = (.files, (try? JSONEncoder().encode(files.map(\.path))) ?? Data(),
                files.map(\.lastPathComponent).prefix(8).joined(separator: ", "))
        } else if let source = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
            source.count <= ClipboardHistoryPolicy.maxEntryBytes, let png = safePNG(source) {
            payload = (.image, png, "圖片 · \(png.count / 1024) KB")
        } else if let text = pasteboard.string(forType: .string), let data = text.data(using: .utf8) {
            payload = (.text, data, text)
        } else { payload = nil }
        guard let (kind, data, summary) = payload, !data.isEmpty,
            data.count <= ClipboardHistoryPolicy.maxEntryBytes else { return }
        let digest = kind.rawValue + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var entry = entries.first { $0.digest == digest }
            ?? ClipboardEntry(kind: kind, data: data, summary: summary, digest: digest)
        entry.copiedAt = Date(); entries.removeAll { $0.digest == digest }; entries.insert(entry, at: 0)
        entries = ClipboardHistoryPolicy.prune(entries, now: Date(), days: days, limit: limit)
        do { try save() } catch { message = error.localizedDescription }
    }

    func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle(); persist()
    }
    func updatePolicy(days: Int, limit: Int) {
        self.days = max(1, min(days, 90)); self.limit = max(1, min(limit, 500))
        if enabled {
            entries = ClipboardHistoryPolicy.prune(entries, now: Date(), days: self.days, limit: self.limit)
            persist(); lastPruned = Date()
        }
    }
    func delete(_ id: UUID) { entries.removeAll { $0.id == id }; persist() }
    func clear() { entries.removeAll(); persist() }
    func copy(_ entry: ClipboardEntry, paste: Bool = false) {
        guard enabled else { return }
        let filePaths: [String]?
        if entry.kind == .files {
            guard let paths = try? JSONDecoder().decode([String].self, from: entry.data),
                !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
                message = "檔案參照格式無效；剪貼簿保持原有內容。"; return
            }
            filePaths = paths
        } else { filePaths = nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.kind {
        case .text: pasteboard.setData(entry.data, forType: .string)
        case .image: pasteboard.setData(entry.data, forType: .png)
        case .files:
            pasteboard.writeObjects((filePaths ?? []).map { NSURL(fileURLWithPath: $0) })
        }
        changeCount = pasteboard.changeCount
        guard paste else { return }
        guard let previousApplication, !previousApplication.isTerminated,
            previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            message = "已複製。請先切換到要貼上的 App，再開啟工作架。"; return
        }
        guard AXIsProcessTrusted() else {
            message = "已複製。自動貼上需要輔助使用權限；你亦可直接按 ⌘V。"; return
        }
        previousApplication.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier else {
                message = "已複製；未能切換到上一個 App。"; return
            }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.postToPid(previousApplication.processIdentifier); up?.postToPid(previousApplication.processIdentifier)
        }
    }

    private func safePNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    private func persist() { do { try save() } catch { message = error.localizedDescription } }
    private func save() throws { try ProStorage.write(entries, to: file) }
}
