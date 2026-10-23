import CoreGraphics
import Foundation

public struct MenuBarMoveJournalEntry: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case planned, nativeMoveFinished, verified }
    public let id: UUID
    public let itemID: String
    public let desiredVisibility: MenuBarVisibility
    public let displayIdentifier: String?
    public let beforeItemID: String?
    public let placement: MenuBarPlacement?
    public let cursor: CGPoint
    public let sourceFrame: CGRect
    public let createdAt: Date
    public var stage: Stage
    public init(
        itemID: String, desiredVisibility: MenuBarVisibility, displayIdentifier: String?, cursor: CGPoint,
        sourceFrame: CGRect, beforeItemID: String? = nil, placement: MenuBarPlacement = .before
    ) {
        id = UUID()
        self.itemID = itemID
        self.desiredVisibility = desiredVisibility
        self.displayIdentifier = displayIdentifier
        self.cursor = cursor
        self.sourceFrame = sourceFrame
        self.beforeItemID = beforeItemID
        self.placement = placement
        createdAt = Date()
        stage = .planned
    }
}

public final class MenuBarMoveJournal {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("move-journal.json") }
    public func pending() throws -> MenuBarMoveJournalEntry? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 100_000 else { throw BarPilotDataError.invalidLayout }
        return try JSONDecoder().decode(MenuBarMoveJournalEntry.self, from: data)
    }
    public func begin(_ entry: MenuBarMoveJournalEntry) throws {
        guard try pending() == nil else { throw MoveJournalError.pendingMove }
        try write(entry)
    }
    public func update(_ entry: MenuBarMoveJournalEntry) throws {
        guard try pending()?.id == entry.id else { throw MoveJournalError.unexpectedMove }
        try write(entry)
    }
    public func complete(_ id: UUID) throws {
        guard let current = try pending() else { return }
        guard current.id == id else { throw MoveJournalError.unexpectedMove }
        try FileManager.default.removeItem(at: url)
    }
    private func write(_ entry: MenuBarMoveJournalEntry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(entry).write(to: url, options: .atomic)
    }
}

public enum MoveJournalError: LocalizedError {
    case pendingMove
    case unexpectedMove
    public var errorDescription: String? {
        switch self {
        case .pendingMove: return L10n.text("上一次移動未完成，請先確認復原紀錄，再開始新的移動。")
        case .unexpectedMove: return L10n.text("復原紀錄已更改，為保留布局，已停止移動。")
        }
    }
}
