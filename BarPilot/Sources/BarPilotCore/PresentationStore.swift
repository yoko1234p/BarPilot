import Foundation

public struct MenuBarPresentationSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let assignments: [MenuBarAssignment]
    public let wasExpanded: Bool
    public let wasSetupMode: Bool
    public init(assignments: [MenuBarAssignment], wasExpanded: Bool, wasSetupMode: Bool) {
        id = UUID()
        capturedAt = Date()
        self.assignments = assignments
        self.wasExpanded = wasExpanded
        self.wasSetupMode = wasSetupMode
    }
}

public final class MenuBarPresentationStore {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("presentation.json") }
    public func load() throws -> MenuBarPresentationSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 2_000_000 else { throw BarPilotDataError.invalidLayout }
        return try JSONDecoder().decode(MenuBarPresentationSnapshot.self, from: data)
    }
    public func saveNew(_ snapshot: MenuBarPresentationSnapshot) throws {
        guard try load() == nil, !snapshot.assignments.isEmpty,
            snapshot.assignments.allSatisfy({ $0.positionVerified == true }),
            Set(snapshot.assignments.map(\.id)).count == snapshot.assignments.count
        else { throw BarPilotDataError.invalidLayout }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count < 2_000_000 else { throw BarPilotDataError.invalidLayout }
        try data.write(to: url, options: .atomic)
    }
    public func finish(_ id: UUID) throws {
        guard let current = try load(), current.id == id else { throw BarPilotDataError.invalidLayout }
        try FileManager.default.removeItem(at: url)
    }
}
