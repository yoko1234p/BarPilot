import AppKit
import BarPilotCore
import Carbon
import Combine

@MainActor
final class BarPilotCommandPalette: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    private let model: BarPilotModel
    private let panel = BarPilotSearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: L10n.text("重新整理"), target: nil, action: nil)
    private var session = PaletteCommandSession()
    private var originatingApplication: NSRunningApplication?
    private weak var originatingWindow: NSWindow?
    private var originatingAXWindow: AXUIElement?
    private var subscriptions = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var updatingTable = false
    private var executing = false
    private var message: String?
    private var matches: [PaletteCommandRow] { session.rows }
    var isVisible: Bool { panel.isVisible }

    init(model: BarPilotModel) {
        self.model = model
        super.init()
        panel.title = L10n.text("BarPilot 快速搜尋")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss(returnFocus: true) }
        panel.onActivate = { [weak self] paste in self?.activateSelection(paste: paste) }
        panel.onSettings = { [weak self] in self?.openSettings() }
        let container = NSView()
        panel.contentView = container
        search.placeholderString = L10n.text("搜尋圖示、布局或動作")
        search.delegate = self
        search.setAccessibilityIdentifier("barpilot.search")
        search.translatesAutoresizingMaskIntoConstraints = false
        let settings = NSButton(
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.text("設定"))!, target: self,
            action: #selector(openSettings))
        settings.isBordered = false
        settings.toolTip = L10n.text("開啟設定／停用管理")
        settings.setAccessibilityIdentifier("barpilot.search-settings")
        settings.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 52
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.allowsEmptySelection = false
        table.setAccessibilityIdentifier("barpilot.search-results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.setAccessibilityIdentifier("barpilot.search-status")
        status.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshResults)
        refreshButton.setAccessibilityIdentifier("barpilot.search-refresh")
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        for view in [search, settings, scroll, status, refreshButton] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -8),
            search.heightAnchor.constraint(equalToConstant: 32),
            settings.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            settings.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            settings.widthAnchor.constraint(equalToConstant: 28), settings.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            status.heightAnchor.constraint(equalToConstant: 40),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            refreshButton.trailingAnchor.constraint(equalTo: settings.trailingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible, !self.executing else { return }
                self.dismiss(returnFocus: false)
            }
        }
        model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.reloadIfVisible() }
        }.store(in: &subscriptions)

    }
    func show() {
        guard !executing else { return }
        if isVisible {
            panel.makeFirstResponder(search)
            return
        }
        originatingApplication = NSWorkspace.shared.frontmostApplication
        originatingWindow = NSApp.keyWindow
        originatingAXWindow = focusedWindow(of: originatingApplication)
        session.open()
        message = nil
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let width = min(560, max(1, visible.width - 24))
            let height = min(440, max(1, visible.height - 40))
            panel.setFrame(
                NSRect(x: visible.midX - width / 2, y: visible.maxY - 24 - height, width: width, height: height),
                display: false)
        }
        search.stringValue = ""
        reload()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        let token = session.token
        Task {
            await model.inventory.refresh()
            guard session.active, session.token == token, isVisible else { return }
            reload()
        }
    }
    private func reload() {
        guard session.active else { return }
        let rows = PaletteCommands.rows(
            menuBar: model.commands, clipboardEnabled: false, clipboard: [],
            automationEnabled: false, widgets: [], rules: [])
        session.reload(PaletteCommands.filter(rows, query: search.stringValue))
        let selected = session.selectedIndex
        updatingTable = true
        table.reloadData()
        if let selected { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        updatingTable = false
        updateStatus()
    }
    private func reloadIfVisible() { if isVisible { reload() } }
    private func updateStatus() {
        let result = message
        status.stringValue =
            (result ?? L10n.text("%1$@ 項 · ↑↓ 選擇 · ↵ 執行 · Esc 返回原 App · ⌘, 設定", String(describing: matches.count)))
            + (result == nil ? "\n" + model.inventory.state.message : "")
        status.textColor = result == nil ? .secondaryLabelColor : .labelColor
        refreshButton.isEnabled = !executing
    }
    func controlTextDidChange(_ notification: Notification) {
        message = nil
        reload()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !matches.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            session.move(delta)
            guard let next = session.selectedIndex else { return true }
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            activateSelection(paste: NSEvent.modifierFlags.contains(.command))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(returnFocus: true)
            return true
        }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingTable else { return }
        session.select(table.selectedRow)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard matches.indices.contains(row) else { return nil }
        let command = matches[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        if case .menuBar(.item(let id)) = command.source,
            let item = model.inventory.items.first(where: { $0.id == id })
        {
            icon.image = NSRunningApplication(processIdentifier: item.pid)?.icon
        }
        if icon.image == nil {
            icon.image =
                NSImage(
                    systemSymbolName: command.symbol,
                    accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: command.subtitle)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26), icon.heightAnchor.constraint(equalToConstant: 26),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
        ])
        cell.setAccessibilityIdentifier("barpilot.search-item.\(command.id)")
        return cell
    }
    @objc private func openSelection() {
        activateSelection(paste: false)
    }
    private func activateSelection(paste: Bool) {
        guard !executing, session.active, let row = session.selection else {
            NSSound.beep()
            return
        }
        message = nil
        do {
            switch row.source {
            case .menuBar(let command):
                guard model.commands.contains(where: { $0.id == row.id && $0.kind == command }) else {
                    throw PaletteCommandError.staleSelection
                }
                dismiss(returnFocus: false)
                Task { await model.runCommand(command) }
            case .clipboard, .widget, .rule:
                throw PaletteCommandError.staleSelection
            }
        } catch { showError(error.localizedDescription) }
    }
    private func focusedWindow(of application: NSRunningApplication?) -> AXUIElement? {
        guard AXIsProcessTrusted(), let application, !application.isTerminated else { return nil }
        let axApplication = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApplication, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
    private func restoreFocus(application: NSRunningApplication?, localWindow: NSWindow?, axWindow: AXUIElement?) {
        guard let application, !application.isTerminated else { return }
        application.activate()
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            localWindow?.makeKeyAndOrderFront(nil)
        } else if let axWindow, AXIsProcessTrusted() {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(application.processIdentifier), kAXFocusedWindowAttribute as CFString,
                axWindow)
        }
    }
    private func dismiss(returnFocus: Bool) {
        guard !executing else { return }
        let application = originatingApplication
        let localWindow = originatingWindow
        let axWindow = originatingAXWindow
        session.close()
        message = nil
        originatingApplication = nil
        originatingWindow = nil
        originatingAXWindow = nil
        panel.orderOut(nil)
        if returnFocus { restoreFocus(application: application, localWindow: localWindow, axWindow: axWindow) }
    }
    private func showError(_ text: String) {
        message = text
        updateStatus()
        NSSound.beep()
    }
    @objc private func refreshResults() {
        guard !executing else { return }
        message = nil
        reload()
        let token = session.token
        Task {
            await model.inventory.refresh()
            guard session.active, session.token == token, isVisible else { return }
            reload()
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        if session.active, !executing { dismiss(returnFocus: false) }
    }
    @objc private func openSettings() {
        guard !executing else { return }
        dismiss(returnFocus: false)
        model.bringMainWindow?()
    }
    func stop() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        subscriptions.removeAll()
        executing = false
        dismiss(returnFocus: false)
        panel.orderOut(nil)
    }
}

private final class BarPilotSearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onActivate: ((Bool) -> Void)?
    var onSettings: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?(event.modifierFlags.contains(.command))
        } else {
            super.keyDown(with: event)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        if event.charactersIgnoringModifiers == "," {
            onSettings?()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            onActivate?(true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class BarPilotHotKey {
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: () -> Void
    let command: BarPilotHotKeyCommand
    init(command: BarPilotHotKeyCommand = .search, action: @escaping () -> Void) {
        self.command = command
        self.action = action
    }
    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let user = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<BarPilotHotKey>.fromOpaque(pointer).takeUnretainedValue()
            var eventID = EventHotKeyID()
            guard
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &eventID) == noErr,
                BarPilotHotKeyCommand.decode(signature: eventID.signature, id: eventID.id) == hotkey.command
            else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in hotkey.action() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, user, &handler) == noErr else {
            return false
        }
        let id = EventHotKeyID(signature: BarPilotHotKeyCommand.signature, id: command.rawValue)
        let modifiers = command == .recover ? controlKey | optionKey | shiftKey : controlKey | optionKey
        guard
            RegisterEventHotKey(
                UInt32(kVK_ANSI_B), UInt32(modifiers), id, GetApplicationEventTarget(), 0,
                &registration) == noErr
        else {
            stop()
            return false
        }
        return true
    }
    func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
