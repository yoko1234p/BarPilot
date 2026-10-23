import AppKit
import BarPilotCore
import Combine
import UniformTypeIdentifiers

/// Orders through the granted MenuBar preferences file. Never changes mouse position or restarts system processes.
@MainActor final class MenuBarPositionService: ObservableObject {
    @Published private(set) var pending: PreferredPositionJournalEntry?
    @Published private(set) var status = L10n.text("排序需授權選單列設定檔")
    @Published private(set) var recoveryBlocked = false
    @Published private(set) var isAuthorized = false
    let preferencesURL: URL
    private let bookmarkURL: URL
    private let journal: PreferredPositionJournal
    private var bookmark: Data?
    private var knownPositions: [String: Any] = [:]
    init(directory: URL, preferencesURL: URL? = nil) {
        self.preferencesURL =
            preferencesURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
        bookmarkURL = directory.appendingPathComponent("menubar-access.bookmark")
        journal = PreferredPositionJournal(directory: directory)
        bookmark = try? Data(contentsOf: bookmarkURL)
        if bookmark != nil { status = L10n.text("已保存排序檔案授權；操作時會重新檢查") }
        do { pending = try journal.load() } catch {
            recoveryBlocked = true
            status = L10n.text("排序復原紀錄無法讀取，已停止寫入以保留原有資料。")
        }
        if bookmark != nil, !recoveryBlocked { validateAccess() }
    }
    func requestAccess() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("允許 BarPilot 排序選單列圖示")
        panel.message = L10n.text("只選擇 com.apple.MenuBar.plist；BarPilot 只更改圖示位置，並保存所改位置以供還原。")
        panel.prompt = L10n.text("授權排序")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = preferencesURL.deletingLastPathComponent()
        panel.nameFieldStringValue = preferencesURL.lastPathComponent
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard selected.standardizedFileURL == preferencesURL.standardizedFileURL,
            selected.resolvingSymlinksInPath() == preferencesURL.resolvingSymlinksInPath()
        else {
            status = L10n.text("請選擇預先指定的 com.apple.MenuBar.plist，未有保存其他檔案授權。")
            return
        }
        let scoped = selected.startAccessingSecurityScopedResource()
        defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
        do {
            _ = try readTable(at: selected)
            let data = try selected.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            // A successful file-panel read does not establish that its saved grant
            // can be reopened. Check that exact path before reporting success.
            var stale = false
            let reopened = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            try validateURL(reopened)
            let reopenedScope = reopened.startAccessingSecurityScopedResource()
            defer { if reopenedScope { reopened.stopAccessingSecurityScopedResource() } }
            _ = try readTable(at: reopened)
            try FileManager.default.createDirectory(
                at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: bookmarkURL, options: .atomic)
            bookmark = data
            isAuthorized = true
            status = L10n.text("排序檔案已授權")
        } catch {
            isAuthorized = false
            status = L10n.text("排序授權未能重開：%1$@", String(describing: error.localizedDescription))
        }
    }
    func validateAccess() {
        do {
            try withAccess { _ = try readTable(at: $0) }
            isAuthorized = true
            status = L10n.text("排序檔案已連接")
        } catch {
            isAuthorized = false
            status = L10n.text("請重新授權排序：%1$@", String(describing: error.localizedDescription))
        }
    }
    func canResolve(_ item: MenuBarItem, liveItems: [MenuBarItem]) -> Bool {
        isAuthorized && (try? MenuBarPreferredPositions.resolve(item, in: knownPositions, liveItems: liveItems)) != nil
    }
    func controlPositionKey() throws -> String {
        let bundle = Bundle.main.bundleIdentifier ?? "local.pakwingho.barpilot"
        for owner in [bundle, "BarPilot"] {
            let key = "status:\(owner)::BarPilot.Control"
            if knownPositions[key].flatMap(MenuBarPreferredPositions.numeric) != nil { return key }
        }
        throw PreferredPositionError.unresolvedIdentity
    }
    /// Diagnostics never change positions or expose bookmark bytes.
    func accessDiagnostics() -> [String: Any] {
        validateAccess()
        return [
            "authorized": isAuthorized, "status": status, "hasBookmark": bookmark != nil,
            "positionCount": knownPositions.count,
            "positions": knownPositions.compactMapValues(MenuBarPreferredPositions.numeric),
        ]
    }
    func move(
        _ source: MenuBarItem, before target: MenuBarItem, liveItems: [MenuBarItem],
        placement: MenuBarPlacement = .before
    ) throws {
        guard !recoveryBlocked, pending == nil, try journal.load() == nil else {
            throw PreferredPositionError.pendingMove
        }
        try withAccess { url in
            let positions = try readTable(at: url)
            let sourceKey = try MenuBarPreferredPositions.resolve(source, in: positions, liveItems: liveItems)
            let targetKey = try MenuBarPreferredPositions.resolve(target, in: positions, liveItems: liveItems)
            let change = try MenuBarPreferredPositions.move(
                sourceKey, before: targetKey, positions: positions, placement: placement)
            let entry = PreferredPositionJournalEntry(
                itemID: source.id, beforeItemID: target.id, displayIdentifier: source.displayIdentifier, change: change,
                sourceKey: sourceKey, targetKey: targetKey, placement: placement)
            try journal.save(entry)
            pending = entry
            // Refresh immediately before writing; a concurrent position change aborts the operation.
            let current = try readTable(at: url)
            let updated = try change.merging(into: current)
            try writeTable(updated, at: url)
            status = L10n.text("排序寫入已送出；正在確認系統位置")
        }
    }
    func waitForPreferenceReadback() async throws {
        guard let entry = pending, !recoveryBlocked else { throw PreferredPositionError.pendingMove }
        try await waitForReadback(entry.change.proposed)
        try verifyPreferenceReadback()
        status = L10n.text("位置已寫入並讀回；等候選單列套用")
    }
    func verifyPreferenceReadback() throws {
        guard let entry = pending, !recoveryBlocked else { throw PreferredPositionError.pendingMove }
        try withAccess { url in
            let positions = try readTable(at: url)
            guard
                entry.change.proposed.allSatisfy({
                    positions[$0.key].flatMap(MenuBarPreferredPositions.numeric) == $0.value
                })
            else {
                throw PreferredPositionError.unexpectedReadback
            }
        }
        if entry.stage != .writeVerified {
            var verified = entry
            verified.stage = .writeVerified
            try journal.save(verified)
            pending = verified
        }
    }
    func completeGeometryVerification() throws {
        guard let entry = pending, entry.stage == .writeVerified else {
            throw PreferredPositionError.unexpectedReadback
        }
        try journal.finish(entry.id)
        pending = nil
        status = L10n.text("選單列排序已驗證")
    }
    func verifyCurrentBindings(_ source: MenuBarItem, before target: MenuBarItem, liveItems: [MenuBarItem]) throws {
        guard let entry = pending, source.id == entry.itemID, target.id == entry.beforeItemID else {
            throw PreferredPositionError.unresolvedIdentity
        }
        try withAccess { url in
            let positions = try readTable(at: url)
            guard try MenuBarPreferredPositions.resolve(source, in: positions, liveItems: liveItems) == entry.sourceKey,
                try MenuBarPreferredPositions.resolve(target, in: positions, liveItems: liveItems) == entry.targetKey
            else { throw PreferredPositionError.unresolvedIdentity }
            guard let sourceKey = entry.sourceKey, let targetKey = entry.targetKey,
                let a = positions[sourceKey].flatMap(MenuBarPreferredPositions.numeric),
                let b = positions[targetKey].flatMap(MenuBarPreferredPositions.numeric),
                (entry.placement ?? .before).isSatisfied(sourcePosition: a, targetPosition: b)
            else { throw PreferredPositionError.unexpectedReadback }
        }
        // MenuBarAgent can replace requested offsets with new pixel positions.
        // The caller has just checked actual AX geometry; both persisted keys
        // must still identify the same widgets in the requested relative order.
        if entry.stage != .writeVerified {
            var verified = entry
            verified.stage = .writeVerified
            try journal.save(verified)
            pending = verified
        }
    }
    func restoreOriginalPositions() async throws {
        guard let entry = pending, !recoveryBlocked else { throw PreferredPositionError.pendingMove }
        try withAccess { url in
            let current = try readTable(at: url)
            let alreadyOriginal = entry.change.original.allSatisfy {
                current[$0.key].flatMap(MenuBarPreferredPositions.numeric) == $0.value
            }
            if !alreadyOriginal {
                let restored = try entry.change.merging(into: current, restoring: true)
                try writeTable(restored, at: url)
            }
        }
        try await waitForReadback(entry.change.original)
        try journal.finish(entry.id)
        pending = nil
        status = L10n.text("原有位置偏好已還原並讀回；系統會重新套用")
    }
    private func waitForReadback(_ expected: [String: Double]) async throws {
        // CFPreferences can acknowledge synchronization before its on-disk file
        // changes. Yield between bounded reads instead of reporting a false failure.
        for attempt in 0..<12 {
            let matches = try withAccess { url in
                let table = try readTable(at: url)
                return expected.allSatisfy { table[$0.key].flatMap(MenuBarPreferredPositions.numeric) == $0.value }
            }
            if matches { return }
            if attempt < 11 { try await Task.sleep(for: .milliseconds(150)) }
        }
        throw PreferredPositionError.unexpectedReadback
    }
    private func readTable(at url: URL) throws -> [String: Any] {
        let table = try PreferredPositionPreferences.read(at: url)
        knownPositions = table
        return table
    }
    private func writeTable(_ table: [String: Any], at url: URL) throws {
        try PreferredPositionPreferences.write(table, at: url)
    }
    private func withAccess<T>(_ action: (URL) throws -> T) throws -> T {
        var stale = false
        let url: URL
        if let bookmark {
            url = try URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        } else {
            throw MenuBarOperationError(message: L10n.text("請先選擇 com.apple.MenuBar.plist，取得排序檔案授權。"))
        }
        try validateURL(url)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if stale {
                _ = try readTable(at: url)
                let refreshed = try url.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                try refreshed.write(to: bookmarkURL, options: .atomic)
                bookmark = refreshed
            }
            return try action(url)
        } catch {
            status = L10n.text("排序未完成：%1$@", String(describing: error.localizedDescription))
            throw error
        }
    }
    private func validateURL(_ url: URL) throws {
        guard url.standardizedFileURL == preferencesURL.standardizedFileURL,
            url.resolvingSymlinksInPath() == preferencesURL.resolvingSymlinksInPath()
        else {
            throw MenuBarOperationError(message: L10n.text("排序授權指向另一個檔案，請重新選擇指定的 com.apple.MenuBar.plist。"))
        }
    }
}
