import Foundation
import Darwin

public final class BarPilotSettingsStore {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("layout.json") }
    public func load() throws -> BarPilotSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return BarPilotSettings() }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw BarPilotDataError.invalidLayout }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_size >= 0, info.st_size < 2_000_000 else { throw BarPilotDataError.invalidLayout }
        let data = try handle.read(upToCount: 2_000_000) ?? Data()
        guard data.count < 2_000_000 else { throw BarPilotDataError.invalidLayout }
        let settings = try JSONDecoder().decode(BarPilotSettings.self, from: data)
        try settings.validate()
        return settings
    }
    public func save(_ settings: BarPilotSettings) throws {
        try settings.validate()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw BarPilotDataError.invalidLayout }
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw BarPilotDataError.invalidLayout }
        } else if errno != ENOENT { throw BarPilotDataError.invalidLayout }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        guard data.count < 2_000_000 else { throw BarPilotDataError.invalidLayout }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum MenuBarMovePlan {
    public static func target(
        visibility: MenuBarVisibility, hiddenDivider: CGRect, alwaysDivider: CGRect
    ) -> CGPoint? {
        guard hiddenDivider.width > 0, alwaysDivider.width > 0,
            hiddenDivider.minX > alwaysDivider.minX, abs(hiddenDivider.midY - alwaysDivider.midY) < 5
        else { return nil }
        let x: CGFloat
        switch visibility {
        case .visible: x = hiddenDivider.maxX + 2
        case .hidden: x = hiddenDivider.minX - 2
        case .alwaysHidden: x = alwaysDivider.minX - 2
        }
        return CGPoint(x: x, y: hiddenDivider.midY)
    }

    public static func classify(
        frame: CGRect, hiddenDivider: CGRect, alwaysDivider: CGRect
    ) -> MenuBarVisibility {
        if frame.midX > hiddenDivider.midX { return .visible }
        if frame.midX > alwaysDivider.midX { return .hidden }
        return .alwaysHidden
    }
}
