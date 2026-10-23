import AppKit
import BarPilotCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

private final class CapsulePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class ProCapsuleController: ObservableObject {
    @Published private(set) var expanded = false
    @Published private(set) var pinned = false
    @Published var dropTargeted = false { didSet { if dropTargeted { expand() } else { scheduleCollapse() } } }
    @Published private(set) var geometry = ProCapsuleGeometry(screenFrame: .zero, topInset: 30, notchWidth: 180)
    private let services: BarPilotProServices
    private let panel = CapsulePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var screen: NSScreen?
    private var selection = "builtin"
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = 0
    var isVisible: Bool { panel.isVisible }
    init(services: BarPilotProServices) {
        self.services = services
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isFloatingPanel = true; panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CapsuleRootView(controller: self, services: services))
        panel.appearance = NSAppearance(named: .darkAqua)
    }
    func start(display: String) -> Bool {
        selection = display
        guard refreshGeometry() else { return false }
        installMonitors(); applyFrame(animated: false); panel.orderFrontRegardless()
        return true
    }
    func stop() {
        hoverTask?.cancel(); collapseTask?.cancel(); expanded = false; pinned = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers.removeAll(); trackingMenus = 0
        panel.orderOut(nil)
    }
    func expand() {
        guard panel.isVisible else { return }
        hoverTask?.cancel(); collapseTask?.cancel(); expanded = true
        applyFrame(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); panel.orderFrontRegardless()
    }
    func collapse(force: Bool = false) {
        if !force && !canCollapse { return }
        hoverTask?.cancel(); collapseTask?.cancel(); pinned = false; expanded = false
        applyFrame(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func togglePin() { pinned.toggle(); if pinned { collapseTask?.cancel() } else { scheduleCollapse() } }
    func hover(_ inside: Bool) {
        hoverTask?.cancel()
        if inside {
            collapseTask?.cancel()
            guard !expanded else { return }
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self, self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.expand()
            }
        } else { scheduleCollapse() }
    }
    func scheduleCollapse() {
        collapseTask?.cancel()
        guard expanded, !pinned else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled, let self else { return }
            if self.canCollapse { self.collapse() }
            else if NSEvent.pressedMouseButtons != 0 && !self.panel.frame.contains(NSEvent.mouseLocation) { self.scheduleCollapse() }
        }
    }
    func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                guard let url = object as? URL else { return }
                Task { @MainActor in self?.services.files.add([url]) }
            }
        }
        return !providers.isEmpty
    }
    private var canCollapse: Bool {
        var state = ProCapsuleInteraction()
        state.pinned = pinned; state.pointerInside = panel.frame.contains(NSEvent.mouseLocation)
        state.mouseDown = NSEvent.pressedMouseButtons != 0; state.dropTargeted = dropTargeted
        let editing = panel.isKeyWindow && panel.firstResponder is NSTextView
        state.hasOverlay = NSApp.modalWindow != nil || panel.attachedSheet != nil || trackingMenus > 0 || editing
        return state.canAutoCollapse
    }
    private func refreshGeometry() -> Bool {
        let available = NSScreen.screens
        let chosen: NSScreen?
        if selection == "builtin" {
            chosen = available.first { $0.safeAreaInsets.top > 0 } ?? available.first { Self.isBuiltIn($0) } ?? NSScreen.main
        } else if selection == "external" {
            chosen = available.first { !Self.isBuiltIn($0) }
        } else { chosen = available.first { Self.identifier($0) == selection } ?? NSScreen.main }
        guard let chosen else { services.notice = "未找到所選螢幕；工作架仍可按需打開。"; panel.orderOut(nil); return false }
        guard !Self.notchHubOccupies(chosen) else {
            services.notice = "NotchHub 正在使用這個螢幕的頂部中央。請選另一個螢幕，或先停用 NotchHub 的面板。"
            panel.orderOut(nil); return false
        }
        screen = chosen
        let inset = chosen.safeAreaInsets.top
        let notch = (chosen.auxiliaryTopLeftArea.flatMap { left in chosen.auxiliaryTopRightArea.map { chosen.frame.width - left.width - $0.width } }) ?? 170
        geometry = ProCapsuleGeometry(screenFrame: chosen.frame, topInset: inset > 0 ? inset : 28, notchWidth: notch)
        applyFrame(animated: false)
        return true
    }
    private func installMonitors() {
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trackingMenus += 1; self?.collapseTask?.cancel() }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus - 1); self.scheduleCollapse()
                }
            },
        ]
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            Task { @MainActor in self?.scheduleCollapse() }
        }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel, event.type == .keyDown, event.keyCode == 53 { self.collapse(force: true); return nil }
            if event.type != .keyDown { self.scheduleCollapse() }
            return event
        }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.refreshGeometry() { self.panel.orderFrontRegardless() }
            }
        }
    }
    private func applyFrame(animated: Bool) {
        let frame = geometry.frame(expanded: expanded)
        if animated {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.22; panel.animator().setFrame(frame, display: true) }
        } else { panel.setFrame(frame, display: true) }
    }
    static func identifier(_ screen: NSScreen) -> String {
        String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }
    private static func isBuiltIn(_ screen: NSScreen) -> Bool { CGDisplayIsBuiltin(UInt32(identifier(screen)) ?? 0) != 0 }
    private static func notchHubOccupies(_ screen: NSScreen) -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "local.pakwingho.notchhub").map(\.processIdentifier))
        guard !pids.isEmpty else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // CGWindow bounds use top-left coordinates, so convert the capsule top anchor once.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let anchor = CGPoint(x: screen.frame.midX, y: primaryTop - screen.frame.maxY + max(10, screen.safeAreaInsets.top / 2))
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.contains(anchor)
        }
    }
}

private struct CapsuleRootView: View {
    @ObservedObject var controller: ProCapsuleController
    @ObservedObject var services: BarPilotProServices
    var body: some View {
        Group {
            if controller.expanded {
                ProShelfView(services: services, pinAction: controller.togglePin, isPinned: controller.pinned)
                    .padding(.top, controller.geometry.topInset)
            } else {
                HStack {
                    Image(systemName: "tray.2.fill").font(.system(size: 14)).frame(width: 34)
                    Spacer(minLength: controller.geometry.notchWidth)
                    Image(systemName: services.settings.media && services.media.playing ? "waveform" : "chevron.down")
                        .font(.system(size: 12)).frame(width: 34)
                }.padding(.horizontal, 10).contentShape(Rectangle()).onTapGesture { controller.expand() }
                    .onDrop(of: [UTType.fileURL], isTargeted: $controller.dropTargeted, perform: controller.drop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 0))
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onHover(perform: controller.hover)
    }
}
