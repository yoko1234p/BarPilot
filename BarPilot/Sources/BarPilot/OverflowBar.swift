import AppKit
import ApplicationServices
import BarPilotCore
import Combine
import SwiftUI

@MainActor final class BarPilotOverflowBar: NSObject, ObservableObject, NSWindowDelegate {
    @Published var query = ""
    @Published var includeAlwaysHidden = false
    @Published private(set) var selectedID: String?
    private let model: BarPilotModel
    private let panel = OverflowPanel(
        contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private var context: OverflowScreenContext?
    private var originatingApplication: NSRunningApplication?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var deactivationTask: Task<Void, Never>?
    private var lastControlInteractionAt = 0.0
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var iconCache: [Int32: NSImage] = [:]
    var isVisible: Bool { panel.isVisible }
    var frame: CGRect? { isVisible ? quartz(panel.frame) : nil }
    var items: [MenuBarItem] {
        MenuBarOverflow.items(
            model.items, settings: model.settings, query: query, includeAlwaysHidden: includeAlwaysHidden)
    }
    init(model: BarPilotModel) {
        self.model = model
        super.init()
        panel.title = L10n.text("BarPilot 圖示列")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss(returnFocus: true) }
        panel.onMove = { [weak self] in self?.moveSelection($0) }
        panel.onActivate = { [weak self] in self?.activateSelected() }
        panel.contentView = NSHostingView(rootView: OverflowBarView(model: model, bar: self))
        model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.reloadIfVisible() }
        }.store(in: &subscriptions)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.dismiss(returnFocus: false) } })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.applicationDeactivated() } })
    }
    /// Called once for a reveal action; the panel never follows subsequent cursor movement.
    func revealIfNeeded(force: Bool = false) -> Bool {
        guard model.sessionIsActive, model.manager.isEnabled, !model.isWorking, !model.manager.isApplying,
            model.inventory.hasPermission,
            let context = captureContext()
        else { return false }
        let expected = model.items.filter {
            MenuBarListFilter.visibility(of: $0, settings: model.settings, native: model.manager.usesAssessment)
                != .alwaysHidden
        }
        guard
            force
                || MenuBarOverflow.requiresPanel(
                    mode: model.overflowMode, items: expected, rightMenuArea: context.rightMenuArea,
                    occlusions: context.occlusions)
        else { return false }
        if isVisible { return true }
        self.context = context
        lastControlInteractionAt = ProcessInfo.processInfo.systemUptime
        originatingApplication = NSWorkspace.shared.frontmostApplication
        query = ""
        includeAlwaysHidden = false
        selectedID = items.first?.id
        // Keep the native strip collapsed; selecting a button reveals only its owner.
        _ = model.manager.hideHidden()
        panel.setFrame(cocoa(context.panelFrame(itemCount: items.count)), display: false)
        installMonitors()
        model.overflowVisible = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.refresh()
        return true
    }
    func icon(for item: MenuBarItem) -> NSImage {
        if let cached = iconCache[item.pid] { return cached }
        let image =
            NSRunningApplication(processIdentifier: item.pid)?.icon
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        iconCache[item.pid] = image
        return image
    }
    func select(_ id: String) { selectedID = id }
    func moveSelection(_ delta: Int) {
        let rows = items
        guard !rows.isEmpty else { return }
        let index = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        selectedID = rows[max(0, min(rows.count - 1, index + delta))].id
    }
    func activateSelected() {
        if let selectedID { activate(selectedID) }
    }
    func activate(_ id: String) {
        guard !model.isWorking, let item = items.first(where: { $0.id == id }), item.canActivate else { return }
        dismiss(returnFocus: true)
        Task { await model.activate(id, revealOnlyOwner: true) }
    }
    func openSettings() {
        dismiss(returnFocus: false)
        model.bringMainWindow?()
    }
    func dismiss(returnFocus: Bool = false) {
        deactivationTask?.cancel()
        deactivationTask = nil
        guard isVisible || model.overflowVisible else { return }
        let previous = originatingApplication
        originatingApplication = nil
        panel.orderOut(nil)
        model.overflowVisible = false
        removeMonitors()
        iconCache.removeAll()
        context = nil
        if returnFocus, let previous, !previous.isTerminated {
            previous.activate()
        }
    }
    private func applicationDeactivated() {
        guard isVisible else { return }
        deactivationTask?.cancel()
        deactivationTask = Task { @MainActor [weak self] in
            // A secondary-screen control is hosted by MenuBarAgent, which can deactivate this
            // panel on mouse-down. Let its mouse-up toggle run before closing for an app switch.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !NSApp.isActive else { return }
            if pointerOverControl(), ProcessInfo.processInfo.systemUptime - lastControlInteractionAt < 0.7 {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                return
            }
            dismiss(returnFocus: false)
        }
    }
    private func reloadIfVisible() {
        guard isVisible else { return }
        guard model.manager.isEnabled, model.inventory.hasPermission else {
            dismiss()
            return
        }
        if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    }
    private func installMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in Task { @MainActor in self?.closeIfOutside() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            if let self, event.windowNumber != panel.windowNumber { closeIfOutside() }
            return event
        }
    }
    private func closeIfOutside() {
        guard isVisible else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) { return }
        if pointerOverControl() {
            lastControlInteractionAt = ProcessInfo.processInfo.systemUptime
            return
        }
        dismiss()
    }
    private func pointerOverControl() -> Bool {
        let point = quartz(NSEvent.mouseLocation)
        return model.manager.controlFrame?.insetBy(dx: -5, dy: -5).contains(point) == true
            || context?.anchor.insetBy(dx: -5, dy: -5).contains(point) == true
    }
    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
    func stop() {
        dismiss()
        removeMonitors()
        subscriptions.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    private func captureContext() -> OverflowScreenContext? {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            return nil
        }
        let bounds = quartz(screen.frame)
        let visible = quartz(screen.visibleFrame)
        let barHeight = max(24, screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let menuBar = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: barHeight)
        let right: CGRect
        if let area = screen.auxiliaryTopRightArea, area.width > 0 {
            right = quartz(area)
        } else {
            let left = max(bounds.minX, frontApplicationMenuRightEdge(in: menuBar) ?? bounds.minX)
            right = CGRect(x: left, y: bounds.minY, width: max(0, bounds.maxX - left), height: barHeight)
        }
        let anchor: CGRect
        if menuBar.contains(quartz(pointer)) {
            anchor = CGRect(x: pointer.x - 12, y: bounds.minY, width: 24, height: barHeight)
        } else if let control = model.manager.controlFrame, bounds.contains(CGPoint(x: control.midX, y: control.midY)) {
            anchor = control
        } else {
            anchor = CGRect(x: bounds.maxX - 180, y: bounds.minY, width: 24, height: barHeight)
        }
        var occlusions = notchHubOcclusions(in: menuBar)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
            right.minX > left.maxX
        {
            occlusions.append(CGRect(x: left.maxX, y: bounds.minY, width: right.minX - left.maxX, height: barHeight))
        }
        return OverflowScreenContext(
            visible: visible, menuBar: menuBar, rightMenuArea: right, anchor: anchor,
            occlusions: occlusions)
    }
}

private struct OverflowScreenContext {
    let visible: CGRect
    let menuBar: CGRect
    let rightMenuArea: CGRect
    let anchor: CGRect
    let occlusions: [CGRect]
    func panelFrame(itemCount: Int) -> CGRect {
        MenuBarOverflow.panelFrame(
            visibleFrame: visible, menuBar: menuBar, anchorX: anchor.maxX,
            preferredWidth: min(900, max(440, CGFloat(itemCount) * 68 + 80)), occlusions: occlusions)
    }
}

private func primaryTop() -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
}
private func quartz(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop() - rect.maxY, width: rect.width, height: rect.height)
}
private func quartz(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryTop() - point.y) }
private func cocoa(_ rect: CGRect) -> CGRect { quartz(rect) }

/// Read only window bounds for our NotchHub integration; no titles, screenshots or window contents.
private func notchHubOcclusions(in menuBar: CGRect) -> [CGRect] {
    let pids = Set(
        NSRunningApplication.runningApplications(withBundleIdentifier: "local.pakwingho.notchhub").map(
            \.processIdentifier))
    guard !pids.isEmpty,
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
    else { return [] }
    return windows.compactMap { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
            (window[kCGWindowLayer as String] as? Int ?? 0) > NSWindow.Level.normal.rawValue,
            (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
            let value = window[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: value as CFDictionary), frame.intersects(menuBar)
        else { return nil }
        return frame
    }
}

private func frontApplicationMenuRightEdge(in menuBar: CGRect) -> CGFloat? {
    guard AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication else { return nil }
    let app = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.1)
    var menu: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menu) == .success,
        let menu, CFGetTypeID(menu) == AXUIElementGetTypeID()
    else { return nil }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(menu as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
        let elements = children as? [AXUIElement]
    else { return nil }
    return elements.prefix(30).compactMap { element -> CGFloat? in
        AXUIElementSetMessagingTimeout(element, 0.1)
        var p: CFTypeRef?
        var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
            let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        let frame = CGRect(origin: point, size: size)
        return frame.intersects(menuBar) ? frame.maxX + 8 : nil
    }.max()
}

private final class OverflowPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 123: onMove?(-1)
        case 124: onMove?(1)
        case 36, 76: onActivate?()
        default: super.keyDown(with: event)
        }
    }
}

private struct OverflowBarView: View {
    @ObservedObject var model: BarPilotModel
    @ObservedObject var bar: BarPilotOverflowBar
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label(L10n.text("圖示列"), systemImage: "menubar.dock.rectangle").font(.callout.weight(.semibold))
                Text("\(bar.items.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("barpilot.overflow.count")
                TextField(L10n.text("搜尋 App"), text: $bar.query).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .onSubmit { bar.activateSelected() }
                    .accessibilityIdentifier("barpilot.overflow.search")
                Spacer(minLength: 0)
                Toggle(L10n.text("長期隱藏"), isOn: $bar.includeAlwaysHidden).toggleStyle(.checkbox).font(.caption)
                    .accessibilityIdentifier("barpilot.overflow.include-hidden")
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.text("重新整理")).accessibilityIdentifier("barpilot.overflow.refresh")
                Button {
                    bar.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(L10n.text("開啟 BarPilot")).accessibilityIdentifier("barpilot.overflow.settings")
                Button {
                    bar.dismiss(returnFocus: true)
                } label: {
                    Image(systemName: "xmark")
                }
                .help(L10n.text("關閉 · Esc")).accessibilityIdentifier("barpilot.overflow.close")
            }
            .buttonStyle(.plain).controlSize(.small)
            HStack(spacing: 5) {
                Button {
                    bar.moveSelection(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityIdentifier("barpilot.overflow.previous")
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 6) {
                            ForEach(bar.items) { item in
                                itemButton(item)
                                    .id(item.id).buttonStyle(.plain)
                                    .disabled(model.isWorking || model.manager.isApplying || !item.canActivate)
                                    .help(item.unavailableReason ?? "\(item.applicationName) · \(item.title)")
                                    .accessibilityLabel(item.applicationName + "，" + item.title)
                                    .accessibilityIdentifier("barpilot.overflow.item." + item.id)
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                    .onChange(of: bar.selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: bar.query) { _, _ in bar.select(bar.items.first?.id ?? "") }
                    .onChange(of: bar.includeAlwaysHidden) { _, _ in bar.select(bar.items.first?.id ?? "") }
                    .overlay {
                        if bar.items.isEmpty { Text(L10n.text("沒有符合的圖示")).font(.callout).foregroundStyle(.secondary) }
                    }
                }
                Button {
                    bar.moveSelection(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityIdentifier("barpilot.overflow.next")
            }
            .buttonStyle(.plain).frame(height: 64)
            Text(L10n.text("點擊開啟原選單 · ← → 選擇 · ↵ 開啟 · Esc 關閉"))
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain).accessibilityIdentifier("barpilot.overflow")
    }
    private func itemButton(_ item: MenuBarItem) -> some View {
        Button {
            bar.activate(item.id)
        } label: {
            VStack(spacing: 5) {
                Image(nsImage: bar.icon(for: item)).resizable().scaledToFit().frame(width: 27, height: 27)
                Text(item.title).font(.system(size: 10)).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 60, height: 54)
            .background(
                bar.selectedID == item.id ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
    }
}
