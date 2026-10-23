import Foundation

/// Keep the recovery control after applications and before the trailing system cluster.
public enum MenuBarControlOrder {
    public static func target(for control: MenuBarItem, in items: [MenuBarItem]) -> MenuBarItem? {
        guard let frame = control.frame else { return nil }
        let sameBar = items.filter {
            guard $0.id != control.id, $0.displayIdentifier == control.displayIdentifier, let other = $0.frame else {
                return false
            }
            return other.width > 0 && other.width < 240 && other.height > 0 && other.height < 64
                && abs(frame.midY - other.midY) < 8
        }
        let apps = sameBar.filter { !$0.bundleIdentifier.hasPrefix("com.apple.") }
        guard let last = apps.max(by: { $0.frame!.midX < $1.frame!.midX }), let appFrame = last.frame else {
            return nil
        }
        let system = sameBar.filter { $0.bundleIdentifier.hasPrefix("com.apple.") && $0.frame!.minX >= appFrame.maxX }
            .min(by: { $0.frame!.minX < $1.frame!.minX })?.frame
        let afterApps = MenuBarPlacement.after.isSatisfied(source: frame, target: appFrame)
        let beforeSystem = system.map { frame.maxX <= $0.minX + 1 } ?? true
        return afterApps && beforeSystem ? nil : last
    }
}
