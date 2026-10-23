import AppKit
import BarPilotCore
import Combine

@MainActor final class MenuBarRevealController: NSObject {
    private weak var model: BarPilotModel?
    private let paletteVisible: () -> Bool
    private let overflowFrame: () -> CGRect?
    private var timing = MenuBarRevealTiming()
    private var timer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var mouseDown = false
    private var lastMouseEventAt = 0.0
    private var trackedMenus = 0
    private var sessionSuspended = false
    private var subscriptions = Set<AnyCancellable>()
    init(model: BarPilotModel, paletteVisible: @escaping () -> Bool, overflowFrame: @escaping () -> CGRect? = { nil }) {
        self.model = model
        self.paletteVisible = paletteVisible
        self.overflowFrame = overflowFrame
        super.init()
    }
    func start() {
        if let model {
            for publisher in [
                model.manager.$isEnabled.eraseToAnyPublisher(), model.manager.$hasTemporaryReveal.eraseToAnyPublisher(),
            ] {
                publisher.removeDuplicates().sink { [weak self] _ in
                    Task { @MainActor in self?.configure() }
                }.store(in: &subscriptions)
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        configure()
    }
    private func installMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in self?.receive(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.receive(event)
            return event
        }
    }
    func configure() {
        timer?.invalidate()
        timer = nil
        timing.reset()
        guard let model else {
            removeMonitors()
            return
        }
        let settings = model.revealSettings
        guard !sessionSuspended, model.manager.isEnabled,
            settings.hoverReveal || settings.automaticallyHide || model.manager.hasTemporaryReveal
        else {
            removeMonitors()
            return
        }
        installMonitors()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
    }
    func manuallyHidden() { timing.manuallyHidden() }
    func suspendForSession() {
        sessionSuspended = true
        trackedMenus = 0
        timing.manuallyHidden()
        configure()
    }
    func resumeAfterSession() {
        sessionSuspended = false
        trackedMenus = 0
        timing.manuallyHidden()
        configure()
    }
    private func receive(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged:
            lastMouseEventAt = ProcessInfo.processInfo.systemUptime
            mouseDown = true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: mouseDown = false
        default: break
        }
        tick()
    }
    private func tick() {
        guard !sessionSuspended, let model, model.sessionIsActive, model.manager.isEnabled,
            model.revealSettings.hoverReveal || model.revealSettings.automaticallyHide
                || model.manager.hasTemporaryReveal,
            let control = model.manager.controlFrame, let point = CGEvent(source: nil)?.location
        else {
            timing.reset()
            return
        }
        var state = MenuBarRevealState()
        state.sessionActive = model.sessionIsActive
        state.managementEnabled = model.manager.isEnabled
        state.expanded = model.manager.hiddenExpanded || model.overflowVisible
        state.temporaryRevealActive = model.manager.hasTemporaryReveal
        state.setupMode = model.manager.isSetupMode || model.presentation != nil
        state.pointerOverControl = control.insetBy(dx: -2, dy: -2).contains(point)
        let display = MenuBarDisplays.current.first { $0.frame.contains(CGPoint(x: control.midX, y: control.midY)) }
        if let display {
            let strip = CGRect(
                x: display.frame.minX, y: control.minY - 2, width: display.frame.width, height: control.height + 4)
            state.pointerOverMenuBar = strip.contains(point)
        }
        if let frame = overflowFrame(), frame.contains(point) { state.pointerOverMenuBar = true }
        let physicallyPressed = [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
        if !physicallyPressed, ProcessInfo.processInfo.systemUptime - lastMouseEventAt > 0.5 { mouseDown = false }
        state.mouseDown = mouseDown || physicallyPressed
        state.menuTracking =
            trackedMenus > 0 || ((state.expanded || state.temporaryRevealActive) && hasNativeMenuOverlay())
        state.paletteVisible = paletteVisible()
        state.editing =
            !state.temporaryRevealActive
            && ((NSApp.keyWindow?.firstResponder as? NSTextView).map { $0.isEditable || $0.hasMarkedText() } ?? false)
        state.working = model.isWorking || model.manager.isApplying
        var settings = model.revealSettings
        if model.manager.hasTemporaryReveal { settings.automaticallyHide = true }
        switch timing.step(state: state, settings: settings, now: ProcessInfo.processInfo.systemUptime) {
        case .none: break
        case .reveal: model.showHiddenItems()
        case .hide:
            if model.manager.hasTemporaryReveal {
                model.manager.endTemporaryReveal()
            } else {
                model.hideHiddenItems(automatic: true)
            }
        }
    }
    private func hasNativeMenuOverlay() -> Bool {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return true }
        return windows.contains { window in
            guard (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                let layer = window[kCGWindowLayer as String] as? Int, layer >= NSWindow.Level.popUpMenu.rawValue,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return rect.height > 32
        }
    }
    @objc private func menuBegan(_ notification: Notification) {
        trackedMenus += 1
        timing.reset()
    }
    @objc private func menuEnded(_ notification: Notification) { trackedMenus = max(0, trackedMenus - 1) }
    func stop() {
        timer?.invalidate()
        timer = nil
        removeMonitors()
        subscriptions.removeAll()
        NotificationCenter.default.removeObserver(self)
    }
    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        mouseDown = false
    }
}
