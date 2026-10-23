import Foundation

public struct DisplayLayoutRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayIDs: [String]
    public var presetID: UUID
    public init(id: UUID = UUID(), displayIDs: [String], presetID: UUID) {
        self.id = id
        self.displayIDs = displayIDs.sorted()
        self.presetID = presetID
    }
    public static func signature(_ displays: [String]) -> String { displays.sorted().joined(separator: "|") }
    public func matches(_ displays: [String]) -> Bool { Set(displayIDs) == Set(displays) }
    public func validate(presets: [MenuBarPreset]) throws {
        guard !displayIDs.isEmpty, displayIDs.count <= 16, Set(displayIDs).count == displayIDs.count,
            displayIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("|") }),
            presets.contains(where: { $0.id == presetID })
        else { throw BarPilotDataError.invalidLayout }
    }
}

public enum MenuBarHiddenReason {
    public static func explain(
        visibility: MenuBarVisibility, enabled: Bool, permission: Bool, protected: Bool,
        setup: Bool, expanded: Bool, temporary: Bool, concealed: Bool,
        frameAvailable: Bool, unavailable: String?
    ) -> String {
        if protected { return L10n.text("macOS 系統控制保持常駐，BarPilot 不會隱藏。") }
        if !enabled { return L10n.text("選單列管理未啟用；目前由 macOS 及原 App 決定是否顯示。") }
        if !permission { return L10n.text("輔助使用權限未開啟，未能核對圖示狀態。") }
        if setup { return L10n.text("正在設定布局，已暫時顯示全部圖示。") }
        if temporary { return L10n.text("正在暫時顯示圖示；結束操作後會回復原有分類。") }
        if concealed {
            return visibility == .alwaysHidden
                ? L10n.text("已設為長期隱藏；一般展開不會顯示，可用第二行或搜尋開啟。") : L10n.text("已設為收納；按 ⋯ 可展開，空間不足會使用第二行。")
        }
        if let unavailable { return unavailable }
        if !frameAvailable { return L10n.text("原 App 未提供圖示位置，暫時無法確認是否被螢幕邊界或劉海遮擋。") }
        switch visibility {
        case .visible: return L10n.text("已設為常駐。如未見圖示，請檢查原 App 或選單列空間。")
        case .hidden: return expanded ? L10n.text("收納區目前已展開；螢幕空間不足時可從第二行開啟。") : L10n.text("已設為收納；按 ⋯ 展開。")
        case .alwaysHidden: return L10n.text("已設為長期隱藏；可用第二行或搜尋開啟。")
        }
    }
}
