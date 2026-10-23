import CoreFoundation
import Foundation

public enum PreferredPositionError: LocalizedError {
    case invalidTable, unresolvedIdentity, ambiguousIdentity, conflictingPositions, pendingMove, unexpectedReadback
    public var errorDescription: String? {
        switch self {
        case .invalidTable: return L10n.text("選單列位置資料格式無效，未有建立或覆蓋位置表。")
        case .unresolvedIdentity: return L10n.text("圖示未能對應到現有位置鍵，未有猜測或改動。")
        case .ambiguousIdentity: return L10n.text("圖示對應多個位置鍵，請重新整理；未有按 App 名稱猜測。")
        case .conflictingPositions: return L10n.text("位置已被系統或另一個 App 改動，復原紀錄仍保留。")
        case .pendingMove: return L10n.text("上次排序未完成，請先驗證或還原原有位置。")
        case .unexpectedReadback: return L10n.text("系統讀回的位置不符，未有標記排序完成。")
        }
    }
}

public enum MenuBarPreferredPositions {
    public static let key = "TrailingItemPreferredPositions"
    public static func numeric(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        guard result.isFinite, result >= 0, result < 1_000_000_000 else { return nil }
        return result
    }
    public static func resolve(_ item: MenuBarItem, in positions: [String: Any], liveItems: [MenuBarItem]? = nil) throws
        -> String
    {
        let prefix = "status:\(item.bundleIdentifier)::"
        var prefixes = [prefix]
        // macOS also saves executable-name owners for some status items. Accept
        // only the name read from the running executable, never a display title.
        if let executable = item.executableName, !executable.isEmpty, !executable.contains(":"),
            let liveItems, liveItems.contains(where: { $0.id == item.id && $0.pid == item.pid }),
            Set(liveItems.filter { $0.executableName == executable }.map(\.bundleIdentifier)) == [item.bundleIdentifier]
        {
            prefixes.append("status:\(executable)::")
        }
        var candidates = Set<String>()
        if let identifier = item.axIdentifier, !identifier.isEmpty {
            if prefixes.contains(where: identifier.hasPrefix)
                || (identifier.hasPrefix("module:")
                    && MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier))
            {
                candidates.insert(identifier)
            }
            candidates.formUnion(prefixes.map { $0 + identifier })
            let suffix = identifier.split(separator: ".").last.map(String.init)?.lowercased()
            let modules: [String: [String]] = [
                "clock": ["module:Clock"], "siri": ["module:Siri", "status:com.apple.systemuiserver::siri"],
                "controlcenter": ["module:BentoBox-0"], "controlcentre": ["module:BentoBox-0"],
                "audiovideo": ["module:AudioVideo"],
                "battery": ["module:Battery"], "wifi": ["module:WiFi"], "bluetooth": ["module:Bluetooth"],
            ]
            if MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier), let suffix {
                candidates.formUnion(modules[suffix] ?? [])
            }
        }
        // A widget's explicit AXHelp/identifier may differ only by separators from its autosave key.
        let labels = [item.axIdentifier, item.axHelp].compactMap { $0 }.map(normalized).filter { !$0.isEmpty }
        for ownerPrefix in prefixes {
            for key in positions.keys where key.hasPrefix(ownerPrefix) {
                if labels.contains(normalized(String(key.dropFirst(ownerPrefix.count)))) { candidates.insert(key) }
            }
        }
        let valid = candidates.filter { positions[$0].flatMap(numeric) != nil }
        if valid.isEmpty, let liveItems {
            // Some menu extras expose no autosave identifier. A current singleton
            // widget and a unique numeric key for that exact owner can be bound;
            // multiple live widgets or historical keys must remain ambiguous.
            let peers = liveItems.filter { $0.bundleIdentifier == item.bundleIdentifier }
            let foreignIdentifier =
                item.axIdentifier.map {
                    ($0.hasPrefix("status:") && !prefixes.contains(where: $0.hasPrefix))
                        || ($0.hasPrefix("module:")
                            && !MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier))
                } ?? false
            let ownerKeys = positions.keys.filter { key in
                prefixes.contains(where: key.hasPrefix) && positions[key].flatMap(numeric) != nil
            }
            if !foreignIdentifier, !MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier),
                peers.count == 1, peers[0].id == item.id, peers[0].pid == item.pid,
                ownerKeys.count == 1
            {
                return ownerKeys[0]
            }
        }
        guard !valid.isEmpty else { throw PreferredPositionError.unresolvedIdentity }
        guard valid.count == 1 else { throw PreferredPositionError.ambiguousIdentity }
        return valid.first!
    }
    private static func normalized(_ string: String) -> String {
        String(string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
    public static func move(
        _ source: String, before target: String, positions: [String: Any], placement: MenuBarPlacement = .before
    ) throws
        -> PreferredPositionChange
    {
        guard source != target, positions[source].flatMap(numeric) != nil, positions[target].flatMap(numeric) != nil
        else {
            throw PreferredPositionError.unresolvedIdentity
        }
        let numbers = positions.compactMapValues(numeric)
        var ordered = numbers.keys.sorted {
            numbers[$0] == numbers[$1] ? $0 < $1 : numbers[$0]! > numbers[$1]!
        }
        ordered.removeAll { $0 == source }
        guard let anchor = ordered.firstIndex(of: target) else { throw PreferredPositionError.unresolvedIdentity }
        let insertion = anchor + (placement == .after ? 1 : 0)
        let lower = insertion < ordered.count ? numbers[ordered[insertion]]! : nil
        let higher = insertion > 0 ? numbers[ordered[insertion - 1]]! : nil
        ordered.insert(source, at: insertion)
        let proposed: Double
        if let lower {
            proposed = higher.map { floor(($0 + lower) / 2) } ?? ceil(lower) + 10
        } else {
            proposed = floor((higher ?? 0) / 2)
        }
        if proposed >= 0, lower.map({ proposed > $0 }) ?? true, higher.map({ proposed < $0 }) ?? true,
            !numbers.contains(where: { $0.key != source && $0.value == proposed })
        {
            return PreferredPositionChange(original: [source: numbers[source]!], proposed: [source: proposed])
        }
        // Dense positions have no integer gap. Re-rank existing numeric keys while preserving every other relative order.
        // Non-numeric, unknown and unrelated preference entries remain untouched.
        guard ordered.count < 20_000 else { throw PreferredPositionError.invalidTable }
        guard Set(numbers.filter { $0.key != source }.map(\.value)).count == numbers.count - 1 else {
            throw PreferredPositionError.ambiguousIdentity
        }
        var original = [String: Double]()
        var changed = [String: Double]()
        for (index, key) in ordered.enumerated() {
            let value = Double((ordered.count - index) * 10)
            if numbers[key] != value {
                original[key] = numbers[key]
                changed[key] = value
            }
        }
        return PreferredPositionChange(original: original, proposed: changed)
    }
}

public enum PreferredPositionPreferences {
    public static func read(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard data.count < 4_000_000,
            let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let positions = root[MenuBarPreferredPositions.key] as? [String: Any], !positions.isEmpty
        else { throw PreferredPositionError.invalidTable }
        // Use the same preference domain for reads and writes. MenuBarAgent and
        // cfprefsd can update the domain before an ordinary file read observes it.
        let domain = url.deletingPathExtension().path as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            let current = CFPreferencesCopyValue(
                MenuBarPreferredPositions.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any], !current.isEmpty
        else { throw PreferredPositionError.invalidTable }
        return current
    }
    public static func write(_ table: [String: Any], at url: URL) throws {
        let domain = url.deletingPathExtension().path as CFString
        CFPreferencesSetValue(
            MenuBarPreferredPositions.key as CFString, table as CFDictionary,
            domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw PreferredPositionError.unexpectedReadback
        }
    }
}

public struct PreferredPositionChange: Codable, Equatable, Sendable {
    public let original: [String: Double]
    public let proposed: [String: Double]
    public init(original: [String: Double], proposed: [String: Double]) {
        self.original = original
        self.proposed = proposed
    }
    public func validate() throws {
        guard !original.isEmpty, Set(original.keys) == Set(proposed.keys),
            original.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1_000_000_000 }),
            proposed.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1_000_000_000 && $0.rounded() == $0 })
        else { throw PreferredPositionError.invalidTable }
    }
    public func merging(into positions: [String: Any], restoring: Bool = false) throws -> [String: Any] {
        try validate()
        let expected = restoring ? proposed : original
        let replacement = restoring ? original : proposed
        guard expected.allSatisfy({ positions[$0.key].flatMap(MenuBarPreferredPositions.numeric) == $0.value }) else {
            throw PreferredPositionError.conflictingPositions
        }
        var updated = positions
        for (key, value) in replacement { updated[key] = NSNumber(value: value) }
        return updated
    }
}

public struct PreferredPositionJournalEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Stage: String, Codable, Sendable { case prepared, writeVerified }
    public let id: UUID
    public let itemID: String
    public let beforeItemID: String
    public let sourceKey: String?
    public let targetKey: String?
    public let placement: MenuBarPlacement?
    public let displayIdentifier: String?
    public let change: PreferredPositionChange
    public let createdAt: Date
    public var stage: Stage
    public init(
        itemID: String, beforeItemID: String, displayIdentifier: String?, change: PreferredPositionChange,
        sourceKey: String? = nil, targetKey: String? = nil, placement: MenuBarPlacement = .before
    ) {
        id = UUID()
        self.itemID = itemID
        self.beforeItemID = beforeItemID
        self.displayIdentifier = displayIdentifier
        self.change = change
        createdAt = Date()
        stage = .prepared
        self.sourceKey = sourceKey
        self.targetKey = targetKey
        self.placement = placement
    }
}

public final class PreferredPositionJournal {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("preferred-position-journal.json") }
    public func load() throws -> PreferredPositionJournalEntry? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 2_000_000 else { throw PreferredPositionError.invalidTable }
        let entry = try JSONDecoder().decode(PreferredPositionJournalEntry.self, from: data)
        try entry.change.validate()
        return entry
    }
    public func save(_ entry: PreferredPositionJournalEntry) throws {
        try entry.change.validate()
        if let pending = try load(), pending.id != entry.id { throw PreferredPositionError.pendingMove }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entry).write(to: url, options: .atomic)
    }
    public func finish(_ id: UUID) throws {
        guard let entry = try load() else { return }
        guard entry.id == id else { throw PreferredPositionError.pendingMove }
        try FileManager.default.removeItem(at: url)
    }
}
