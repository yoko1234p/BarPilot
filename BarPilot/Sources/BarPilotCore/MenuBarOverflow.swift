import CoreGraphics
import Foundation

public enum MenuBarOverflowMode: String, Codable, CaseIterable, Sendable {
    case automatic, always
    public var title: String { self == .automatic ? L10n.text("空間不足時用第二行") : L10n.text("每次使用第二行") }
}

public enum MenuBarOverflow {
    public static func items(
        _ items: [MenuBarItem], settings: BarPilotSettings, query: String = "", includeAlwaysHidden: Bool = false
    ) -> [MenuBarItem] {
        MenuBarSearch.filter(items, query: query).filter {
            $0.bundleIdentifier != "local.pakwingho.barpilot" && !$0.bundleIdentifier.hasPrefix("com.apple.")
                && (includeAlwaysHidden || settings.assignment(for: $0.id).visibility != .alwaysHidden)
        }
    }

    /// All rectangles use global Quartz coordinates, including displays left of or above the primary display.
    public static func requiresPanel(
        mode: MenuBarOverflowMode, items: [MenuBarItem], rightMenuArea: CGRect, occlusions: [CGRect],
        controlWidth: CGFloat = 24
    ) -> Bool {
        if mode == .always { return true }
        guard !items.isEmpty, rightMenuArea.width > 0 else { return false }
        if items.contains(where: { item in
            guard let frame = item.frame else { return false }
            return occlusions.contains(where: frame.intersects)
        }) {
            return true
        }
        let leftEdge =
            occlusions.filter { $0.intersects(rightMenuArea) }.map(\.maxX).max()
            .map { max(rightMenuArea.minX, $0 + 8) } ?? rightMenuArea.minX
        let available = max(0, rightMenuArea.maxX - leftEdge - 10)
        let width = items.reduce(controlWidth + 12) { total, item in
            let measured = item.frame?.width ?? 28
            let bounded = measured.isFinite && measured > 0 && measured < 240 ? measured : 28
            return total + bounded + 6
        }
        return width > available
    }

    public static func panelFrame(
        visibleFrame: CGRect, menuBar: CGRect, anchorX: CGFloat, preferredWidth: CGFloat,
        occlusions: [CGRect], preferredHeight: CGFloat = 150
    ) -> CGRect {
        let inset = min(12, max(0, visibleFrame.width / 8))
        let width = max(1, min(preferredWidth, visibleFrame.width - 2 * inset))
        let height = max(1, min(preferredHeight, visibleFrame.height - 2 * inset))
        let x = max(visibleFrame.minX + inset, min(anchorX - width, visibleFrame.maxX - inset - width))
        var y = max(visibleFrame.minY + 8, menuBar.maxY + 8)
        for obstruction in occlusions.sorted(by: { $0.minY < $1.minY }) {
            let candidate = CGRect(x: x, y: y, width: width, height: height)
            if candidate.intersects(obstruction) { y = obstruction.maxY + 8 }
        }
        y = min(y, visibleFrame.maxY - inset - height)
        return CGRect(x: x, y: max(visibleFrame.minY + inset, y), width: width, height: height)
    }
    public static func mergingVisibleInventory(
        _ fresh: [MenuBarItem], remembered: [MenuBarItem], concealedOwners: Set<String>, runningPIDs: Set<Int32>
    ) -> [MenuBarItem] {
        var seen = Set(fresh.map(\.id))
        return fresh
            + remembered.filter {
                concealedOwners.contains($0.bundleIdentifier) && runningPIDs.contains($0.pid)
                    && seen.insert($0.id).inserted
            }
    }

}
