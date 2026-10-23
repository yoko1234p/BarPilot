import Foundation

/// One projection for category counts and rows, including mandatory system visibility.
public enum MenuBarListFilter {
    public static func visibility(of item: MenuBarItem, settings: BarPilotSettings, native: Bool) -> MenuBarVisibility {
        if native, MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier) { return .visible }
        return settings.assignment(for: item.id).visibility
    }
    public static func items(
        _ items: [MenuBarItem], settings: BarPilotSettings, query: String = "", display: String? = nil,
        group: UUID? = nil, visibility: MenuBarVisibility? = nil, native: Bool = true
    ) -> [MenuBarItem] {
        MenuBarSearch.filter(items, query: query).filter { item in
            (display == nil || item.displayIdentifier == display || item.displayIdentifier == nil)
                && (group == nil || settings.assignment(for: item.id).groupID == group)
                && (visibility == nil || Self.visibility(of: item, settings: settings, native: native) == visibility)
        }
    }
}
