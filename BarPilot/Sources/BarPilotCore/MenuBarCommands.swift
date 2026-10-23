import Foundation

public enum MenuBarMainAction: String, CaseIterable, Sendable {
    case settings, workspace, shelf, showHidden, hideHidden, showAll, presentation, restorePresentation
    public var title: String {
        switch self {
        case .settings: return L10n.text("選單列設定")
        case .workspace: return L10n.text("開啟工作台")
        case .shelf: return L10n.text("開啟工作架")
        case .showHidden: return L10n.text("展開收納圖示")
        case .hideHidden: return L10n.text("收起圖示")
        case .showAll: return L10n.text("展開全部／設置")
        case .presentation: return L10n.text("開始簡報模式")
        case .restorePresentation: return L10n.text("還原簡報前布局")
        }
    }
    public var keywords: String {
        switch self {
        case .settings: return "settings preferences 設定"
        case .workspace: return "workspace widgets 工作台"
        case .shelf: return "shelf tray clipboard 工作架"
        case .showHidden: return "show reveal hidden 展開"
        case .hideHidden: return "hide collapse hidden 收起"
        case .showAll: return "show all setup 設置 全部"
        case .presentation: return "presentation meeting focus 簡報 專注"
        case .restorePresentation: return "restore presentation 還原 恢復"
        }
    }
}
public enum MenuBarCommandKind: Equatable, Sendable {
    case item(String)
    case preset(UUID)
    case action(MenuBarMainAction)
}
public struct MenuBarCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: String
    public let kind: MenuBarCommandKind
    public init(id: String, title: String, subtitle: String, keywords: String = "", kind: MenuBarCommandKind) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.kind = kind
    }
}
public enum MenuBarCommandSearch {
    public static func filter(_ commands: [MenuBarCommand], query: String) -> [MenuBarCommand] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return commands.filter { command in
            let text = "\(command.title) \(command.subtitle) \(command.keywords)"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
