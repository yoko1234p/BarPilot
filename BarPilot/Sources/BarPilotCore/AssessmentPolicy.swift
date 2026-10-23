import Foundation

/// Assessment Mode addresses application owners, not individual status-item widgets.
public struct MenuBarAssessmentPolicy: Equatable, Sendable {
    public let concealedBundles: Set<String>
    public let allowedBundles: [String]
    public let mixedOwners: Set<String>

    public static let protectedBundles: Set<String> = [
        "local.pakwingho.barpilot",
        "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.MenuBarAgent",
        "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.dock",
    ]

    public static func make(
        items: [MenuBarItem], settings: BarPilotSettings, runningBundles: Set<String>, ownBundle: String,
        expanded: Bool, temporaryReveals: Set<String> = []
    ) -> Self {
        var hidden = Set<String>()
        var mixed = Set<String>()
        for (bundle, group) in Dictionary(grouping: items, by: \.bundleIdentifier) {
            guard !bundle.isEmpty, bundle != ownBundle, runningBundles.contains(bundle),
                !protectedBundles.contains(bundle)
            else { continue }
            let visibilities = Set(group.map { settings.assignment(for: $0.id).visibility })
            // An imported mixed owner stays visible until the user makes one explicit owner-wide choice.
            guard visibilities.count == 1, let visibility = visibilities.first else {
                mixed.insert(bundle)
                continue
            }
            if visibility == .alwaysHidden || (visibility == .hidden && !expanded) { hidden.insert(bundle) }
        }
        hidden.subtract(temporaryReveals)
        let allowed = runningBundles.union(protectedBundles).union([ownBundle]).subtracting(hidden)
        return Self(
            concealedBundles: hidden, allowedBundles: allowed.filter { !$0.isEmpty }.sorted(), mixedOwners: mixed)
    }
}

/// Rejects asynchronous completion from a request invalidated by reveal, disable, or a newer configuration.
public struct MenuBarAssessmentGeneration: Sendable {
    public private(set) var value: UInt64 = 0
    public init() {}
    @discardableResult public mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }
    public func accepts(_ request: UInt64) -> Bool { request == value }
}
