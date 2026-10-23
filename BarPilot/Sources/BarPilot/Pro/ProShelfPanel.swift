import AppKit
import SwiftUI

private final class ProShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ProShelfPanelController: NSObject, NSWindowDelegate {
    private let services: BarPilotProServices
    private let panel: NSPanel
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    init(services: BarPilotProServices) {
        self.services = services
        panel = ProShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "BarPilot 工作架"; panel.isFloatingPanel = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ProShelfView(services: services))
        panel.delegate = self
    }
    func show() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(780, visible.width - 24); let height = min(520, visible.height - 24)
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 8, width: width, height: height), display: true)
        panel.alphaValue = 0; panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; panel.animator().alphaValue = 1 }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        // Wait until mouse-up so dragging a file from Finder into the shelf does not dismiss its target.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, !self.panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            return event
        }
    }
    func close() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        panel.orderOut(nil)
    }
}

struct ProShelfView: View {
    @ObservedObject var services: BarPilotProServices
    var pinAction: (() -> Void)? = nil
    var isPinned = false
    @State private var tab = ProFeature.shelf
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("BarPilot 工作架", systemImage: "tray.2.fill").font(.headline)
                Spacer()
                if let pinAction {
                    Button(action: pinAction) { Image(systemName: isPinned ? "pin.fill" : "pin") }.help("保持展開")
                }
                Button { services.bringMainWindow?() } label: { Image(systemName: "gearshape") }.help("工作台設定")
                Button { services.closeShelf() } label: { Image(systemName: "xmark") }.keyboardShortcut(.escape, modifiers: [])
            }.buttonStyle(.borderless).padding(16)
            HStack(spacing: 8) {
                ForEach(ProFeature.allCases.filter { $0 != .automation && services.isEnabled($0) }) { feature in
                    Button { tab = feature } label: { Label(feature.name, systemImage: feature.symbol).labelStyle(.iconOnly).frame(width: 36, height: 30) }
                        .background(tab == feature ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .buttonStyle(.plain).help(feature.name)
                }
                Spacer()
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ScrollView { ProFeatureContent(services: services, feature: tab).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
            if services.settings.automation, !services.automation.widgets.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(services.automation.widgets) { widget in
                            Button { services.automation.run(widget.action) } label: { Label(widget.name, systemImage: widget.symbol) }
                        }
                    }.padding(12)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.12)))
        .onChange(of: services.settings) { _, _ in if !services.isEnabled(tab) { tab = .shelf } }
    }
}
