import Foundation

public enum BarPilotStatusAction: Equatable { case menu, search, requiresManagement, reveal, conceal }
public enum BarPilotStatusControl {
    public static func action(
        rightClick: Bool, control: Bool, option: Bool,
        managementEnabled: Bool, expanded: Bool
    ) -> BarPilotStatusAction {
        if rightClick || control { return .menu }
        if option { return .search }
        guard managementEnabled else { return .requiresManagement }
        return expanded ? .conceal : .reveal
    }
}
