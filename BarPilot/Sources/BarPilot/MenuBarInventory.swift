import AppKit
import ApplicationServices
import BarPilotCore
import Combine

enum MenuBarInventoryState: Equatable {
    case permissionRequired
    case loading
    case ready
    case empty
    case partial(Int)
    case failed(String)
    var message: String {
        switch self {
        case .permissionRequired: return L10n.text("允許輔助使用後，才能讀取及操作真實選單列項目。")
        case .loading: return L10n.text("正在讀取各 App 的選單列…")
        case .ready: return L10n.text("已連接選單列")
        case .empty: return L10n.text("暫未讀到項目。開啟所需 App 或展開其選單列圖示，再重新整理。")
        case .partial(let count): return L10n.text("部分 App 未回應（%1$@）；已顯示可讀取的項目。", String(describing: count))
        case .failed(let message): return message
        }
    }
}

struct MenuBarOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct RunningMenuApplication: Sendable {
    let pid: Int32
    let bundle: String
    let name: String
    let executableName: String?
}
private struct MenuBarAXSnapshot {
    var items: [MenuBarItem] = []
    var elements: [String: AXUIElement] = [:]
    var failures = 0
}

@MainActor final class MenuBarInventoryService: ObservableObject {
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var state: MenuBarInventoryState = .permissionRequired
    private var elements: [String: AXUIElement] = [:]
    private var generation = 0
    private var scanTask: Task<MenuBarAXSnapshot, Never>?
    var savedOwnIdentifiers: [String: String] = [:]
    var hasPermission: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func refresh() async {
        generation += 1
        scanTask?.cancel()
        let request = generation
        guard hasPermission else {
            items = []
            elements = [:]
            state = .permissionRequired
            return
        }
        state = .loading
        let profiles = NSWorkspace.shared.runningApplications.compactMap { app -> RunningMenuApplication? in
            guard !app.isTerminated, let bundle = app.bundleIdentifier,
                bundle != Bundle.main.bundleIdentifier
            else { return nil }
            return RunningMenuApplication(
                pid: app.processIdentifier, bundle: bundle, name: app.localizedName ?? bundle,
                executableName: app.executableURL?.lastPathComponent)
        }
        let displays = MenuBarDisplays.current
        let aliases = savedOwnIdentifiers
        let task = Task.detached(priority: .userInitiated) {
            MenuBarAXScanner.scan(profiles, displays: displays, savedOwnIdentifiers: aliases)
        }
        scanTask = task
        let snapshot = await task.value
        guard generation == request else { return }
        guard hasPermission else {
            items = []
            elements = [:]
            state = .permissionRequired
            return
        }
        items = snapshot.items.sorted {
            if let a = $0.frame, let b = $1.frame, abs(a.midY - b.midY) < 8 { return a.minX < b.minX }
            return $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
        }
        elements = snapshot.elements
        state = snapshot.failures > 0 ? .partial(snapshot.failures) : items.isEmpty ? .empty : .ready
    }
    func activate(_ item: MenuBarItem) async throws {
        guard hasPermission else { throw MenuBarOperationError(message: L10n.text("輔助使用權限未開啟，請先允許 BarPilot。")) }
        guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated,
            app.bundleIdentifier == item.bundleIdentifier, let element = elements[item.id]
        else { throw MenuBarOperationError(message: L10n.text("這個 App 已退出或圖示已改變；請重新整理再試。")) }
        let previousMenus = nativeMenuWindowIDs(pid: item.pid)
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result == .cannotComplete {
            // A modal menu can start tracking before AXPress replies. Confirm the new native menu
            // instead of reporting failure and immediately concealing its owner again.
            try await Task.sleep(for: .milliseconds(100))
            if !nativeMenuWindowIDs(pid: item.pid).subtracting(previousMenus).isEmpty { return }
        }
        guard result == .success else {
            throw MenuBarOperationError(
                message: L10n.text(
                    "%1$@ 未接受 AXPress（%2$@）。請直接點擊原有圖示，或重新整理。", String(describing: item.applicationName),
                    String(describing: result.rawValue)))
        }
    }
    private func nativeMenuWindowIDs(pid: Int32) -> Set<Int> {
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Set(
            windows.compactMap { window in
                guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                    (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                    (window[kCGWindowLayer as String] as? Int ?? 0) >= NSWindow.Level.floating.rawValue,
                    let bounds = window[kCGWindowBounds as String] as? [String: Any],
                    let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 50,
                    rect.height > 32
                else { return nil }
                return window[kCGWindowNumber as String] as? Int
            })
    }
    func currentItem(_ id: String) throws -> MenuBarItem {
        guard hasPermission, let item = items.first(where: { $0.id == id }),
            let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated,
            app.bundleIdentifier == item.bundleIdentifier, let element = elements[id],
            let frame = MenuBarAXScanner.rectangle(element)
        else { throw MenuBarOperationError(message: L10n.text("圖示位置已失效，請重新整理後再試。")) }
        return MenuBarItem(
            id: item.id, bundleIdentifier: item.bundleIdentifier, applicationName: item.applicationName,
            title: item.title, pid: item.pid, frame: frame, canActivate: item.canActivate,
            hasStableIdentity: item.hasStableIdentity, unavailableReason: item.unavailableReason,
            displayIdentifier: item.displayIdentifier, axIdentifier: item.axIdentifier, axHelp: item.axHelp,
            executableName: item.executableName)
    }
    func refreshGeometry() {
        items = items.compactMap { try? currentItem($0.id) }.sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
    }
}

private enum MenuBarAXScanner {
    static func scan(
        _ profiles: [RunningMenuApplication], displays: [BarPilotDisplay], savedOwnIdentifiers: [String: String]
    ) -> MenuBarAXSnapshot {
        var snapshot = MenuBarAXSnapshot()
        for profile in profiles {
            guard !Task.isCancelled else { break }
            let app = AXUIElementCreateApplication(profile.pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &value)
            if result == .cannotComplete {
                snapshot.failures += 1
                continue
            }
            if result != .success,
                profile.bundle == "com.apple.systemuiserver" || profile.bundle == "com.apple.controlcenter"
            {
                _ = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value)
            }
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let root = unsafeBitCast(value, to: AXUIElement.self)
            let children = descendants(root, depth: 0)
            var occurrences: [String: Int] = [:]
            for child in children {
                guard !Task.isCancelled else { break }
                AXUIElementSetMessagingTimeout(child, 0.2)
                let identifier: String? = attribute(child, kAXIdentifierAttribute)
                let description: String? = attribute(child, kAXDescriptionAttribute)
                let title: String? = attribute(child, kAXTitleAttribute)
                let help: String? = attribute(child, kAXHelpAttribute)
                let base = MenuBarIdentity.make(
                    bundle: profile.bundle, identifier: identifier, description: description, title: title,
                    occurrence: 0)
                let occurrence = occurrences[base.id, default: 0]
                occurrences[base.id] = occurrence + 1
                let identity = MenuBarIdentity.make(
                    bundle: profile.bundle, identifier: identifier, description: description, title: title,
                    occurrence: occurrence, savedOwnIdentifiers: savedOwnIdentifiers)
                let label = [description, title, identifier].compactMap { $0 }.first { !$0.isEmpty } ?? profile.name
                var names: CFArray?
                let canActivate =
                    AXUIElementCopyActionNames(child, &names) == .success
                    && (names as? [String])?.contains(kAXPressAction) == true
                let frame = rectangle(child)
                let item = MenuBarItem(
                    id: identity.id, bundleIdentifier: profile.bundle, applicationName: profile.name,
                    title: label, pid: profile.pid, frame: frame, canActivate: canActivate,
                    hasStableIdentity: identity.stable,
                    unavailableReason: canActivate ? nil : L10n.text("這個圖示未提供 AXPress；可直接點擊原有圖示。"),
                    displayIdentifier: frame.flatMap { rect in
                        displays.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }?.id
                    }, axIdentifier: identifier, axHelp: help, executableName: profile.executableName)
                snapshot.items.append(item)
                snapshot.elements[item.id] = child
            }
        }
        return snapshot
    }
    static func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 3, !Task.isCancelled else { return [] }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        return Array(children.prefix(80)).flatMap { child in
            AXUIElementSetMessagingTimeout(child, 0.2)
            let role: String = attribute(child, kAXRoleAttribute) ?? ""
            if role == kAXMenuBarItemRole || role == "AXMenuExtra" { return [child] }
            return descendants(child, depth: depth + 1)
        }
    }
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    static func rectangle(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
            let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
            AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
            dimensions.width > 0, dimensions.height > 0
        else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
