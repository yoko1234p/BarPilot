import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PaletteCommandSource: Equatable {
    case menuBar(MenuBarCommandKind)
    case clipboard(id: UUID, kind: ClipboardKind, digest: String)
    case widget(id: UUID, expectedAction: ProAction)
    case rule(id: UUID, expectedAction: ProAction)
}

public struct PaletteCommandRow: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: String
    public let symbol: String
    public let source: PaletteCommandSource
}

public enum PaletteClipboardPayload: Equatable {
    case text(Data)
    case png(Data)
    case files([String])
}

public enum PaletteCommandError: Error, LocalizedError, Equatable {
    case staleSelection, clipboardDisabled, invalidClipboard, missingClipboardFiles
    case automationDisabled, automationBusy, changedAction, missingPreset, shelfDisabled
    case invalidShortcut, invalidScript

    public var errorDescription: String? {
        switch self {
        case .staleSelection: return L10n.text("這一項已移除或更改；請重新整理後再選擇。")
        case .clipboardDisabled: return L10n.text("剪貼簿歷史已停用；請在工作台重新啟用。")
        case .invalidClipboard: return L10n.text("剪貼簿紀錄格式無效；請刪除這項，再複製一次。原有剪貼簿未有更改。")
        case .missingClipboardFiles: return L10n.text("紀錄中的檔案已移動或刪除；請重新複製檔案。原有剪貼簿未有更改。")
        case .automationDisabled: return L10n.text("自動化已停用；請在工作台重新啟用。")
        case .automationBusy: return L10n.text("另一個動作仍在執行；請等候完成後再試。")
        case .changedAction: return L10n.text("動作已更改或停用；請重新整理，核對新動作後再執行。")
        case .missingPreset: return L10n.text("這個布局已移除；請編輯動作，選擇現有布局。")
        case .shelfDisabled: return L10n.text("工作架未啟用；請先在工作台啟用。")
        case .invalidShortcut: return L10n.text("捷徑名稱無效；請編輯動作，填寫現有捷徑的完整名稱。")
        case .invalidScript: return L10n.text("腳本無法讀取或設定無效；請編輯動作，重新選擇 .sh、.zsh、.py 或 .js 檔案。")
        }
    }
}

public enum PaletteCommands {
    /// Uses only an already enabled history; it never reads or enables the system clipboard.
    public static func rows(
        menuBar: [MenuBarCommand], clipboardEnabled: Bool, clipboard: [ClipboardEntry],
        automationEnabled: Bool, widgets: [ProActionWidget], rules: [ProAutomationRule]
    ) -> [PaletteCommandRow] {
        var result = menuBar.map {
            PaletteCommandRow(
                id: $0.id, title: $0.title, subtitle: $0.subtitle, keywords: $0.keywords,
                symbol: $0.subtitle == L10n.text("布局") ? "rectangle.3.group" : "command", source: .menuBar($0.kind))
        }
        if clipboardEnabled {
            result += clipboard.map { entry in
                let type: String
                let symbol: String
                switch entry.kind {
                case .text:
                    type = L10n.text("文字")
                    symbol = "doc.on.clipboard"
                case .image:
                    type = L10n.text("圖片")
                    symbol = "photo"
                case .files:
                    type = L10n.text("檔案")
                    symbol = "doc"
                }
                let title = entry.summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return PaletteCommandRow(
                    id: "clipboard:\(entry.id)",
                    title: title.isEmpty ? L10n.text("剪貼簿%1$@", String(describing: type)) : String(title.prefix(160)),
                    subtitle: L10n.text("剪貼簿 · %1$@ · ↵ 複製 · ⌘↵ 貼上", String(describing: type))
                        + (entry.pinned ? L10n.text(" · 已釘選") : ""),
                    keywords: "clipboard history copy paste \(entry.kind.rawValue) 剪貼簿 複製 貼上 " + entry.summary,
                    symbol: symbol, source: .clipboard(id: entry.id, kind: entry.kind, digest: entry.digest))
            }
        }
        if automationEnabled {
            result += widgets.map {
                PaletteCommandRow(
                    id: "widget:\($0.id)", title: String($0.name.prefix(160)),
                    subtitle: L10n.text("動作按鈕 · ") + $0.action.label, keywords: "automation action widget 自動化 動作 按鈕",
                    symbol: $0.symbol, source: .widget(id: $0.id, expectedAction: $0.action))
            }
            result += rules.filter(\.enabled).map {
                PaletteCommandRow(
                    id: "rule:\($0.id)", title: String($0.name.prefix(160)),
                    subtitle: L10n.text("規則動作（手動，不檢查條件） · ") + $0.action.label,
                    keywords: "automation rule manual 自動化 規則 手動",
                    symbol: "bolt", source: .rule(id: $0.id, expectedAction: $0.action))
            }
        }
        return result
    }

    public static func filter(_ rows: [PaletteCommandRow], query: String) -> [PaletteCommandRow] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { row in
            let text = "\(row.title) \(row.subtitle) \(row.keywords)"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public static func clipboardEntry(
        for source: PaletteCommandSource, enabled: Bool, entries: [ClipboardEntry]
    ) throws -> ClipboardEntry {
        guard enabled else { throw PaletteCommandError.clipboardDisabled }
        guard case .clipboard(let id, let kind, let digest) = source,
            let entry = entries.first(where: { $0.id == id }), entry.kind == kind, entry.digest == digest
        else { throw PaletteCommandError.staleSelection }
        guard !entry.data.isEmpty, entry.data.count <= ClipboardHistoryPolicy.maxEntryBytes else {
            throw PaletteCommandError.invalidClipboard
        }
        if entry.kind == .text, String(data: entry.data, encoding: .utf8) == nil {
            throw PaletteCommandError.invalidClipboard
        }
        return entry
    }

    public static func filePaths(
        for entry: ClipboardEntry, isAvailable: (String) -> Bool
    ) throws -> [String] {
        guard entry.kind == .files, !entry.data.isEmpty, entry.data.count <= ClipboardHistoryPolicy.maxEntryBytes,
            let paths = try? JSONDecoder().decode([String].self, from: entry.data), !paths.isEmpty,
            paths.count <= 4096, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") })
        else { throw PaletteCommandError.invalidClipboard }
        guard paths.allSatisfy(isAvailable) else { throw PaletteCommandError.missingClipboardFiles }
        return paths
    }

    public static func clipboardPayload(
        for entry: ClipboardEntry, isFileAvailable: (String) -> Bool
    ) throws -> PaletteClipboardPayload {
        guard !entry.data.isEmpty, entry.data.count <= ClipboardHistoryPolicy.maxEntryBytes else {
            throw PaletteCommandError.invalidClipboard
        }
        switch entry.kind {
        case .files: return .files(try filePaths(for: entry, isAvailable: isFileAvailable))
        case .text:
            guard String(data: entry.data, encoding: .utf8) != nil else {
                throw PaletteCommandError.invalidClipboard
            }
            return .text(entry.data)
        case .image:
            guard let source = CGImageSourceCreateWithData(entry.data as CFData, nil),
                CGImageSourceGetType(source) as String? == UTType.png.identifier,
                CGImageSourceGetStatus(source) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                (1...4096).contains(width.intValue), (1...4096).contains(height.intValue),
                CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
            else { throw PaletteCommandError.invalidClipboard }
            return .png(entry.data)
        }
    }

    public static func automationAction(
        for source: PaletteCommandSource, enabled: Bool, running: Bool,
        widgets: [ProActionWidget], rules: [ProAutomationRule]
    ) throws -> ProAction {
        guard enabled else { throw PaletteCommandError.automationDisabled }
        guard !running else { throw PaletteCommandError.automationBusy }
        switch source {
        case .widget(let id, let expected):
            guard let widget = widgets.first(where: { $0.id == id }), widget.action == expected else {
                throw PaletteCommandError.changedAction
            }
            return widget.action
        case .rule(let id, let expected):
            guard let rule = rules.first(where: { $0.id == id }), rule.enabled, rule.action == expected else {
                throw PaletteCommandError.changedAction
            }
            return rule.action
        default: throw PaletteCommandError.staleSelection
        }
    }

    public static func validate(
        action: ProAction, presets: Set<UUID>, shelfEnabled: Bool, isReadableScript: (String) -> Bool
    ) throws {
        switch action {
        case .preset(let id):
            guard presets.contains(id) else { throw PaletteCommandError.missingPreset }
        case .showShelf:
            guard shelfEnabled else { throw PaletteCommandError.shelfDisabled }
        case .shortcut(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
                !name.contains("\0")
            else { throw PaletteCommandError.invalidShortcut }
        case .localScript(let path, let arguments):
            guard path.hasPrefix("/"), !path.contains("\0"), path.count <= 4096,
                ["sh", "zsh", "py", "js"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                arguments.count <= 50, arguments.allSatisfy({ $0.count <= 4096 && !$0.contains("\0") }),
                isReadableScript(path)
            else { throw PaletteCommandError.invalidScript }
        }
    }
}

/// Keeps a stable selection across live refreshes and rejects delayed work after dismissal.
public struct PaletteCommandSession {
    public private(set) var token = UUID()
    public private(set) var active = false
    public private(set) var rows: [PaletteCommandRow] = []
    public private(set) var selectedID: String?
    public var selectedIndex: Int? { rows.firstIndex { $0.id == selectedID } }
    public var selection: PaletteCommandRow? { selectedIndex.map { rows[$0] } }
    public init() {}
    public mutating func open() {
        token = UUID()
        active = true
        rows = []
        selectedID = nil
    }
    public mutating func reload(_ values: [PaletteCommandRow]) {
        guard active else { return }
        rows = values
        if !values.contains(where: { $0.id == selectedID }) { selectedID = values.first?.id }
    }
    public mutating func select(_ index: Int) {
        selectedID = rows.indices.contains(index) && active ? rows[index].id : nil
    }
    public mutating func move(_ delta: Int) {
        guard active, !rows.isEmpty else { return }
        select(min(rows.count - 1, max(0, (selectedIndex ?? 0) + delta)))
    }
    public mutating func close() {
        active = false
        rows = []
        selectedID = nil
        token = UUID()
    }
}
