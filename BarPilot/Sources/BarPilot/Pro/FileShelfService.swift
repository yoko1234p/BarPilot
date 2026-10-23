import AppKit
import BarPilotCore
import Combine
import Quartz

@MainActor
final class FileShelfService: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    @Published private(set) var items: [ShelfReference] = []
    @Published private(set) var enabled = false
    @Published var message: String?
    private let file: URL
    private var previewURL: NSURL?
    init(directory: URL) { file = directory.appendingPathComponent("file-shelf.json"); super.init() }
    func setEnabled(_ value: Bool) {
        enabled = value
        guard value else { items = []; return }
        do { items = try ProStorage.read([ShelfReference].self, at: file, maxBytes: 2 * 1024 * 1024) ?? [] }
        catch { message = error.localizedDescription }
    }
    func add(_ urls: [URL]) {
        guard enabled else { return }
        for url in urls where url.isFileURL {
            guard items.count < 100, !items.contains(where: { $0.originalPath == url.path }),
                FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                items.append(ShelfReference(url: url, bookmark: bookmark))
            } catch { message = error.localizedDescription }
        }
        save()
    }
    func chooseFiles() {
        guard enabled else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func resolve(_ item: ShelfReference) -> URL? {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: item.bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? URL(fileURLWithPath: item.originalPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func open(_ item: ShelfReference) { if let url = resolve(item) { NSWorkspace.shared.open(url) } else { message = "原始檔案已移走或不可用。" } }
    func reveal(_ item: ShelfReference) { if let url = resolve(item) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func quickLook(_ item: ShelfReference) {
        guard let url = resolve(item), let panel = QLPreviewPanel.shared() else { message = "原始檔案不可用。"; return }
        previewURL = url as NSURL; panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func airDrop(_ item: ShelfReference) {
        guard let url = resolve(item), let service = NSSharingService(named: .sendViaAirDrop) else { message = "AirDrop 現時不可用。"; return }
        service.perform(withItems: [url])
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL }
    private func save() { do { try ProStorage.write(items, to: file) } catch { message = error.localizedDescription } }
}
