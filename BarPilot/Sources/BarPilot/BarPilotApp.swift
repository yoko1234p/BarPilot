import AppKit
import ApplicationServices
import BarPilotCore
import BarPilotNative
import SwiftUI

@MainActor final class BarPilotDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: BarPilotModel
    private var status: NSStatusItem!
    private var window: NSWindow?
    private var palette: BarPilotCommandPalette!
    private var overflow: BarPilotOverflowBar!
    private var hotkey: BarPilotHotKey!
    private var recoveryHotkey: BarPilotHotKey!
    private var reveal: MenuBarRevealController!
    private var session: MenuBarSessionController!
    private var observers: [NSObjectProtocol] = []
    private var pendingURL: URL?
    private var previousWindowApplication: NSRunningApplication?
    private var statusMenu: NSMenu?
    override init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(index + 1),
            arguments[index + 1].hasPrefix("/")
        {
            model = BarPilotModel(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        } else {
            model = BarPilotModel()
        }
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.positions.validateAccess()
        let menu = NSMenu()
        let application = NSMenuItem(title: "BarPilot", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "BarPilot")
        let show = NSMenuItem(title: L10n.text("開啟 BarPilot"), action: #selector(showMainWindow), keyEquivalent: ",")
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("結束 BarPilot"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        application.submenu = appMenu
        menu.addItem(application)
        let editItem = NSMenuItem(title: L10n.text("編輯"), action: nil, keyEquivalent: "")
        let editing = NSMenu(title: L10n.text("編輯"))
        for (title, action, key) in [
            (L10n.text("復原"), "undo:", "z"), (L10n.text("剪下"), "cut:", "x"),
            (L10n.text("複製"), "copy:", "c"), (L10n.text("貼上"), "paste:", "v"), (L10n.text("全選"), "selectAll:", "a"),
        ] {
            editing.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editing
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        model.bringMainWindow = { [weak self] in
            self?.model.selectedTab = 0
            self?.showMainWindow()
        }
        model.showShelfAction = { [weak self] in self?.showSearchPalette() }
        model.showWorkspaceAction = { [weak self] in self?.openNotchHub() }
        model.showProShelfAction = { [weak self] in self?.openNotchHub(shelf: true) }
        palette = BarPilotCommandPalette(model: model)
        overflow = BarPilotOverflowBar(model: model)
        model.revealOverflowIfNeeded = { [weak self] in self?.overflow.revealIfNeeded() ?? false }
        model.showOverflowAction = { [weak self] in _ = self?.overflow.revealIfNeeded(force: true) }
        model.hideOverflowAction = { [weak self] in self?.overflow.dismiss() }
        status = NSStatusBar.system.statusItem(withLength: 26)
        status.autosaveName = "BarPilot.Control"
        status.behavior = []
        status.isVisible = true
        model.manager.controlItem = status
        model.manager.refreshAfterFullscreen = { [weak self] in self?.model.refresh() }
        status.button?.image = NSImage(
            systemSymbolName: "ellipsis", accessibilityDescription: L10n.text("BarPilot 控制"))?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        status.button?.image?.size = NSSize(width: 16, height: 16)
        status.button?.image?.isTemplate = true
        status.button?.imageScaling = .scaleProportionallyDown
        if status.button?.image == nil { status.button?.title = "⋯" }
        status.button?.toolTip = L10n.text("BarPilot：點擊展開／收起選單列圖示；右鍵開啟 App 設定；⌥ 搜尋。須先啟用管理。")
        status.button?.setAccessibilityIdentifier("barpilot.status")
        status.button?.target = self
        status.button?.action = #selector(statusClick)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.restoreStatusIconAction = { [weak self] in self?.recoverControl() }
        model.manager.restoreControl = { [weak self] in self?.status.isVisible = true }
        reveal = MenuBarRevealController(
            model: model, paletteVisible: { [weak self] in self?.palette.isVisible ?? false },
            overflowFrame: { [weak self] in self?.overflow.frame })
        model.revealSettingsDidChange = { [weak self] in self?.reveal.configure() }
        model.manuallyHidden = { [weak self] in self?.reveal.manuallyHidden() }
        reveal.start()
        session = MenuBarSessionController(
            suspend: { [weak self] in
                self?.reveal.suspendForSession()
                self?.model.suspendForSession()
            },
            resume: { [weak self] in
                guard let self else { return }
                await model.resumeAfterSession()
                if !Task.isCancelled { reveal.resumeAfterSession() }
            })
        session.start()
        hotkey = BarPilotHotKey { [weak self] in self?.showSearchPalette() }
        if !hotkey.register() { model.notice = L10n.text("⌃⌥B 已被其他 App 使用；仍可從 BarPilot 選單開啟搜尋。") }
        recoveryHotkey = BarPilotHotKey(command: .recover) { [weak self] in self?.recoverControl() }
        model.recoveryHotkeyAvailable = recoveryHotkey.register()
        if !model.recoveryHotkeyAvailable { model.notice = L10n.text("⌃⌥⇧B 已被佔用；仍可從 Finder 再開 BarPilot 恢復圖示。") }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in self?.model.refresh() }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.model.refresh() }
            })
        if !model.manager.competingManagers.isEmpty {
            model.notice =
                L10n.text(
                    "偵測到 %1$@；BarPilot 未啟用管理，也未移動其他 App 的圖示。",
                    String(describing: model.manager.competingManagers.joined(separator: "、")))
        }
        model.refresh()
        model.restoreManagementAtLaunch()
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in
                        self?.model.manager.verifyControlSoon()
                        self?.model.scheduleControlPin()
                    }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) {
                [weak self] notification in
                Task { @MainActor in
                    guard let self, let moved = notification.object as? NSWindow,
                        moved === self.status.button?.window
                    else { return }
                    self.model.scheduleControlPin()
                }
            })
        // A login item should restore menu bar control without raising settings.
        // Explicit test profiles and --show-window still exercise the full UI.
        if CommandLine.arguments.contains("--show-window") || CommandLine.arguments.contains("--data-directory") {
            showMainWindow()
        }
        if let pendingURL {
            self.pendingURL = nil
            self.application(NSApp, open: [pendingURL])
        }
    }
    @objc private func statusClick() {
        let event = NSApp.currentEvent
        let modifiers = event?.modifierFlags ?? []
        switch BarPilotStatusControl.action(
            rightClick: event?.type == .rightMouseDown || event?.type == .rightMouseUp,
            control: modifiers.contains(.control), option: modifiers.contains(.option),
            managementEnabled: model.manager.isEnabled,
            expanded: model.manager.hiddenExpanded || model.overflowVisible)
        {
        case .menu: showStatusMenu()
        case .search: showSearchPalette()
        case .requiresManagement:
            model.notice = L10n.text("右鍵開啟 BarPilot，先啟用選單列管理。")
            NSSound.beep()
        case .conceal: model.hideHiddenItems()
        case .reveal: model.showHiddenItems()
        }
    }
    private func showStatusMenu() {
        let menu = NSMenu()
        statusMenu = menu
        for (title, selector) in [
            (L10n.text("開啟 BarPilot…"), #selector(showMainWindow)),
            (L10n.text("搜尋圖示    ⌃⌥B"), #selector(searchItems)),
            (L10n.text("開啟第二行圖示列"), #selector(showOverflow)),
            (L10n.text("展開收納"), #selector(showHidden)), (L10n.text("收起圖示"), #selector(hideHidden)),
            (L10n.text("展開全部／設置"), #selector(setupItems)),
            (L10n.text("NotchHub 工作台…"), #selector(showWorkspaceShelf)),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if window?.isVisible == true {
            let hide = NSMenuItem(
                title: L10n.text("收起 BarPilot 視窗"), action: #selector(hideMainWindow), keyEquivalent: "")
            hide.target = self
            menu.insertItem(hide, at: 1)
        }
        if !model.settings.presets.isEmpty {
            menu.addItem(.separator())
            for preset in model.settings.presets {
                let item = NSMenuItem(
                    title: L10n.text("套用 %1$@", String(describing: preset.name)), action: #selector(applyPreset),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("結束 BarPilot"), action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        // MenuBarAgent hosts this button remotely on macOS 27. Anchor in screen coordinates;
        // presenting in its proxy view can lose the menu when that scene is replaced.
        let point: NSPoint
        if let button = status.button, let host = button.window {
            let bottom = host.convertPoint(
                toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.minY), to: nil))
            let top = host.convertPoint(
                toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.maxY), to: nil))
            point = NSPoint(x: bottom.x, y: min(bottom.y, top.y) - 8)
        } else {
            point = NSEvent.mouseLocation
        }
        menu.popUp(positioning: nil, at: point, in: nil)
    }
    private func makeMainWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "BarPilot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 900, height: 610)
        window.setFrameAutosaveName("BarPilot.MainWindow")
        if !window.setFrameUsingName("BarPilot.MainWindow") { window.center() }
        window.contentView = NSHostingView(rootView: BarPilotMainView(model: model))
        self.window = window
        return window
    }
    @objc func showMainWindow() {
        let window = makeMainWindowIfNeeded()
        status?.isVisible = true
        if let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            previousWindowApplication = front
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func recoverControl() {
        if model.manager.isEnabled { model.manager.showAllForSetup() }
        status.isVisible = true
        model.notice = L10n.text("控制圖示已恢復，暫時展開全部圖示；分類及布局保留。")
        showMainWindow()
    }
    @objc private func hideMainWindow() {
        window?.orderOut(nil)
        if NSApp.isActive, let previousWindowApplication, !previousWindowApplication.isTerminated {
            previousWindowApplication.activate()
        }
        previousWindowApplication = nil
    }
    private func showSearchPalette() {
        overflow.dismiss()
        palette.show()
    }
    @objc private func searchItems() { showSearchPalette() }
    @objc private func showOverflow() { _ = overflow.revealIfNeeded(force: true) }
    @objc private func showHidden() { model.showHiddenItems() }
    @objc private func hideHidden() { model.hideHiddenItems() }
    @objc private func setupItems() { model.showAllItems() }
    @objc private func showWorkspaceShelf() { openNotchHub() }
    private func openNotchHub(shelf: Bool = false) {
        let url = URL(string: shelf ? "notchhub://shelf" : "notchhub://home")!
        if !NSWorkspace.shared.open(url) {
            model.notice = L10n.text("請先從 Work Applications 開啟已安裝的 NotchHub。")
            showMainWindow()
        }
    }
    @objc private func applyPreset(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { Task { await model.applyPreset(id) } }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        recoverControl()
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "barpilot" else { return }
        guard status != nil else {
            pendingURL = url
            return
        }
        switch url.host {
        case "recover": recoverControl()
        case "show": showMainWindow()
        case "search": showSearchPalette()
        case "icons": _ = overflow.revealIfNeeded(force: true)
        case "workspace": openNotchHub()
        case "shelf": openNotchHub(shelf: true)
        case "preset": if let id = UUID(uuidString: url.lastPathComponent) { Task { await model.applyPreset(id) } }
        default: break
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        recoveryHotkey.stop()
        palette.stop()
        overflow.stop()
        session.stop()
        reveal.stop()
        model.manager.disable()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@main enum BarPilotMain {
    @MainActor static func main() {
        if L10n.catalog.printDiagnosticsIfRequested() { return }
        if CommandLine.arguments.contains("--position-status") {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BarPilot", isDirectory: true)
            let positions = MenuBarPositionService(directory: directory)
            if let data = try? JSONSerialization.data(
                withJSONObject: positions.accessDiagnostics(), options: .sortedKeys)
            {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        if CommandLine.arguments.contains("--backend-status") {
            let result: [String: Any] = [
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "assessmentAvailable": BPAssessmentAssertion.capabilityError() == nil,
                "capabilityError": BPAssessmentAssertion.capabilityError() ?? "",
                "allowedSystemItemCount": MenuBarSystemItems.all?.count ?? 0,
                "accessibility": AXIsProcessTrusted(),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
                let json = String(data: data, encoding: .utf8)
            {
                print(json)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = BarPilotDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
