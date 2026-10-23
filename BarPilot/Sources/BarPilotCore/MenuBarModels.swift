import CoreGraphics
import Foundation

public enum MenuBarVisibility: String, Codable, CaseIterable, Sendable {
    case visible
    case hidden
    case alwaysHidden

    public var title: String {
        switch self {
        case .visible: return L10n.text("常駐")
        case .hidden: return L10n.text("收納")
        case .alwaysHidden: return L10n.text("長期隱藏")
        }
    }
}

public enum MenuBarPlacement: String, Codable, Sendable {
    case before, after

    public func isSatisfied(sourcePosition: Double, targetPosition: Double) -> Bool {
        guard sourcePosition.isFinite, targetPosition.isFinite, sourcePosition >= 0, targetPosition >= 0 else {
            return false
        }
        return self == .before ? sourcePosition > targetPosition : sourcePosition < targetPosition
    }

    public func isSatisfied(source: CGRect, target: CGRect) -> Bool {
        guard source.width > 0, target.width > 0, source.width < 240, target.width < 240,
            source.height > 0, target.height > 0, source.height < 64, target.height < 64,
            abs(source.midY - target.midY) < 8
        else { return false }
        return self == .before ? source.maxX <= target.minX + 1 : source.minX >= target.maxX - 1
    }
}

public struct MenuBarItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let bundleIdentifier: String
    public let applicationName: String
    public let title: String
    public let pid: Int32
    public let frame: CGRect?
    public let canActivate: Bool
    public let hasStableIdentity: Bool
    public let unavailableReason: String?
    public let displayIdentifier: String?
    public let axIdentifier: String?
    public let axHelp: String?
    public let executableName: String?

    public init(
        id: String, bundleIdentifier: String, applicationName: String, title: String, pid: Int32,
        frame: CGRect?, canActivate: Bool, hasStableIdentity: Bool, unavailableReason: String? = nil,
        displayIdentifier: String? = nil, axIdentifier: String? = nil, axHelp: String? = nil,
        executableName: String? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.pid = pid
        self.frame = frame
        self.canActivate = canActivate
        self.hasStableIdentity = hasStableIdentity
        self.unavailableReason = unavailableReason
        self.displayIdentifier = displayIdentifier
        self.axIdentifier = axIdentifier
        self.axHelp = axHelp
        self.executableName = executableName
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum MenuBarIdentity {
    /// Our single-control apps must not acquire a new identity when their UI language changes.
    public static let ownStatusBundles: Set<String> = [
        "local.pakwingho.barpilot", "local.pakwingho.capturetext", "local.pakwingho.devworkbench",
        "local.pakwingho.edgenotes", "local.pakwingho.notchhub", "local.pakwingho.quickswitch",
        "local.pakwingho.selectionbar", "local.pakwingho.superpilot",
    ]

    public static func savedOwnStatusIdentifiers(in settings: BarPilotSettings) -> [String: String] {
        // Retain an existing unambiguous ID, so layouts/groups need no migration or rewrite.
        let records = settings.assignments + settings.presets.flatMap(\.assignments)
        var candidates: [String: Set<String>] = [:]
        for record in records {
            let parts = record.id.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.last == "0", ownStatusBundles.contains(String(parts[0])) else { continue }
            candidates[String(parts[0]), default: []].insert(record.id)
        }
        return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    public static func make(
        bundle: String, identifier: String?, description: String?, title: String?, occurrence: Int,
        savedOwnIdentifiers: [String: String] = [:]
    ) -> (id: String, stable: Bool) {
        if occurrence == 0, ownStatusBundles.contains(bundle) {
            return (savedOwnIdentifiers[bundle] ?? "\(bundle)|status|0", true)
        }
        let candidates = [identifier, description, title].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let value = candidates.first { !$0.isEmpty }
        let label = (value ?? "unnamed").precomposedStringWithCanonicalMapping.lowercased()
        let escaped = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? label
        return ("\(bundle)|\(escaped)|\(occurrence)", value != nil)
    }
}

public struct MenuBarAssignment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var visibility: MenuBarVisibility
    public var groupID: UUID?
    public var order: Int
    public var positionVerified: Bool?
    public var visibilityApplied: Bool?
    public init(
        id: String, visibility: MenuBarVisibility = .visible, groupID: UUID? = nil, order: Int = 0,
        positionVerified: Bool? = nil, visibilityApplied: Bool? = nil
    ) {
        self.id = id
        self.visibility = visibility
        self.groupID = groupID
        self.order = order
        self.positionVerified = positionVerified
        self.visibilityApplied = visibilityApplied
    }
}

public struct MenuBarGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct MenuBarPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var assignments: [MenuBarAssignment]
    public var displayIdentifier: String?
    public init(id: UUID = UUID(), name: String, assignments: [MenuBarAssignment], displayIdentifier: String? = nil) {
        self.id = id
        self.name = name
        self.assignments = assignments
        self.displayIdentifier = displayIdentifier
    }
}

public struct BarPilotSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var managementEnabled = false
    public var assignments: [MenuBarAssignment] = []
    public var groups: [MenuBarGroup] = []
    public var presets: [MenuBarPreset] = []
    public var reveal: MenuBarRevealSettings?
    public var overflowMode: MenuBarOverflowMode?
    public var automaticDisplayLayouts: Bool?
    public var displayLayoutRules: [DisplayLayoutRule]?
    public init() {}

    public func assignment(for id: String) -> MenuBarAssignment {
        assignments.first { $0.id == id } ?? MenuBarAssignment(id: id)
    }
    public mutating func assign(_ assignment: MenuBarAssignment) {
        if let index = assignments.firstIndex(where: { $0.id == assignment.id }) {
            assignments[index] = assignment
        } else {
            assignments.append(assignment)
        }
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw BarPilotDataError.unsupportedSchema }
        let rules = displayLayoutRules ?? []
        guard rules.count <= 32, Set(rules.map(\.id)).count == rules.count,
            Set(rules.map { DisplayLayoutRule.signature($0.displayIDs) }).count == rules.count
        else { throw BarPilotDataError.invalidLayout }
        for rule in rules { try rule.validate(presets: presets) }
        guard Set(assignments.map(\.id)).count == assignments.count,
            Set(groups.map(\.id)).count == groups.count, Set(presets.map(\.id)).count == presets.count,
            groups.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw BarPilotDataError.invalidLayout }
        let groupIDs = Set(groups.map(\.id))
        let allAssignments = assignments + presets.flatMap(\.assignments)
        guard allAssignments.allSatisfy({ !$0.id.isEmpty && ($0.groupID == nil || groupIDs.contains($0.groupID!)) }),
            presets.allSatisfy({ Set($0.assignments.map(\.id)).count == $0.assignments.count })
        else {
            throw BarPilotDataError.invalidLayout
        }
    }
}

public enum BarPilotDataError: LocalizedError {
    case unsupportedSchema
    case invalidLayout
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return L10n.text("設定版本較新，未有修改原有設定檔。")
        case .invalidLayout: return L10n.text("設定包含重複或無效的分組，未有覆蓋原有設定。")
        }
    }
}

public enum MenuBarSearch {
    public static func filter(_ items: [MenuBarItem], query: String) -> [MenuBarItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            let searchable = "\(item.title) \(item.applicationName) \(item.bundleIdentifier)"
            return words.allSatisfy {
                searchable.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
