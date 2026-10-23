import AppKit
import ApplicationServices
import BarPilotCore
import BarPilotNative
import Combine

@MainActor final class MenuBarManager: NSObject, ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var hiddenExpanded = true
    @Published private(set) var isSetupMode = false
    @Published private(set) var issue: String?
    @Published private(set) var isApplying = false
    @Published private(set) var concealedBundles: Set<String> = []
    @Published private(set) var hasTemporaryReveal = false
    @Published private(set) var isRecoveringSession = false
    private(set) var sessionSuspended = false
    private let runtime: MenuBarManagerRuntime
    private var suspendedVisibility: (setup: Bool, expanded: Bool)?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration: UInt64 = 0
    private var canOperate: Bool { !sessionSuspended && runtime.desktopInteractive() }
    private var temporaryBundles: Set<String> = []
    private var returnExpanded = false
    private var unrestrictedActivation = false
    var usesAssessment: Bool { runtime.usesAssessment }
    var backendDescription: String {
        usesAssessment ? L10n.text("macOS 27 · 原生隱藏／偏好排序") : L10n.text("macOS 26 · 分隔線管理")
    }
    private var generation = MenuBarAssessmentGeneration()
    private var completion: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var nativeTask: Task<Void, Never>?
    private var nativeItems: [MenuBarItem] = []
    private var nativeSettings = BarPilotSettings()
    private var lastPolicy: MenuBarAssessmentPolicy?
    weak var controlItem: NSStatusItem?
    var restoreControl: (() -> Void)?
    private var controlCheckTask: Task<Void, Never>?
    private var hiddenDivider: NSStatusItem?
    private var alwaysDivider: NSStatusItem?
    private var moving = false
    private var hasVerifiedLaunchLocation: Bool { runtime.verifiedLaunchLocation() }

    init(runtime: MenuBarManagerRuntime? = nil) {
        self.runtime = runtime ?? MenuBarManagerRuntime()
        super.init()
    }

    var competingManagers: [String] { runtime.competingManagers() }
    func enable() throws {
        guard canOperate else { throw MenuBarOperationError(message: L10n.text("請先喚醒螢幕並解鎖，再啟用管理。")) }
        guard competingManagers.isEmpty else {
            throw MenuBarOperationError(
                message: L10n.text(
                    "%1$@ 正在管理選單列。請先自行結束它，再啟用 BarPilot，避免兩者拉動同一圖示。",
                    String(describing: competingManagers.joined(separator: "、"))))
        }
        guard !isEnabled else { return }
        if usesAssessment {
            guard hasVerifiedLaunchLocation else {
                throw MenuBarOperationError(message: L10n.text("請從應用程式內的 BarPilot 安裝版啟動，再啟用管理；其他副本會令系統隱藏控制圖示。"))
            }
            if let error = runtime.capabilityError() { throw MenuBarOperationError(message: error) }
            isEnabled = true
            showAllForSetup()
            return
        }
        hiddenDivider = makeDivider(
            name: "BarPilot.HiddenDivider", symbol: "chevron.left", label: L10n.text("BarPilot 收納分隔線"))
        alwaysDivider = makeDivider(
            name: "BarPilot.AlwaysDivider", symbol: "lock", label: L10n.text("BarPilot 長期隱藏分隔線"))
        isEnabled = true
        showAllForSetup()
    }
    func disable() {
        cancelSessionRecovery()
        suspendedVisibility = nil
        unrestrictedActivation = false
        temporaryBundles = []
        hasTemporaryReveal = false
        cancelNative()
        for item in [hiddenDivider, alwaysDivider].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        hiddenDivider = nil
        alwaysDivider = nil
        isEnabled = false
        hiddenExpanded = true
        isSetupMode = false
        issue = nil
    }
    func suspendForSession() {
        guard !sessionSuspended else { return }
        let expanded = hasTemporaryReveal ? returnExpanded : hiddenExpanded
        suspendedVisibility = (isSetupMode, expanded)
        let rememberedOwners = concealedBundles.union(nativePolicy(expanded: expanded).concealedBundles)
        sessionSuspended = true
        cancelSessionRecovery()
        controlCheckTask?.cancel()
        controlCheckTask = nil
        if isApplying {
            // Reject its late callback without turning an unavailable lock-screen hit test into setup mode.
            let owners = concealedBundles
            cancelNative()
            concealedBundles = owners
        } else {
            nativeTask?.cancel()
            nativeTask = nil
        }
        if hasTemporaryReveal {
            hiddenExpanded = returnExpanded
            unrestrictedActivation = false
            temporaryBundles = []
            hasTemporaryReveal = false
            lastPolicy = nil
        }
        concealedBundles = rememberedOwners
    }
    func resumeAfterSession(items: [MenuBarItem], settings: BarPilotSettings) {
        guard !Task.isCancelled, runtime.desktopInteractive() else { return }
        nativeItems = items
        nativeSettings = settings
        sessionSuspended = false
        if let saved = suspendedVisibility {
            isSetupMode = saved.setup
            hiddenExpanded = saved.expanded
            suspendedVisibility = nil
        }
        guard isEnabled, !isSetupMode else { return }
        // The system can replace the underlying assertion during sleep, even when its policy is unchanged.
        lastPolicy = nil
        if usesAssessment {
            recoverSessionVisibility(expanded: hiddenExpanded)
        } else if hiddenExpanded {
            _ = showHidden()
        } else {
            _ = hideHidden()
        }
    }
    func restoreVisibilityAfterOperation(setup: Bool, expanded: Bool) {
        guard isEnabled else { return }
        if !canOperate {
            // An interrupted reorder must retain its pre-operation state, not its temporary setup state.
            isSetupMode = setup
            hiddenExpanded = expanded
            if sessionSuspended { suspendedVisibility = (setup, expanded) }
        } else if setup {
            showAllForSetup()
        } else if expanded {
            _ = showHidden()
        } else {
            _ = hideHidden()
        }
    }
    private func makeDivider(name: String, symbol: String, label: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 22)
        item.autosaveName = name
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.button?.setAccessibilityIdentifier(name)
        item.button?.setAccessibilityLabel(label)
        item.button?.toolTip = L10n.text("按住 ⌘ 拖動圖示：鎖左邊長期隱藏，鎖與箭嘴之間收納，箭嘴右邊常駐。")
        item.button?.target = self
        item.button?.action = #selector(dividerClicked)
        return item
    }
    @objc private func dividerClicked() { _ = hiddenExpanded ? hideHidden() : showHidden() }
    func showAllForSetup() {
        guard canOperate, isEnabled else { return }
        cancelSessionRecovery()
        unrestrictedActivation = false
        temporaryBundles = []
        hasTemporaryReveal = false
        if usesAssessment { cancelNative() }
        isSetupMode = true
        hiddenExpanded = true
        hiddenDivider?.length = 22
        alwaysDivider?.length = 22
        issue = nil
    }
    @discardableResult func showHidden() -> Bool {
        guard canOperate, isEnabled else { return false }
        cancelSessionRecovery()
        unrestrictedActivation = false
        temporaryBundles = []
        hasTemporaryReveal = false
        if usesAssessment { return requestNative(expanded: true) }
        if isSetupMode && !validateDividerOrder() { return false }
        isSetupMode = false
        hiddenExpanded = true
        hiddenDivider?.length = 22
        alwaysDivider?.length = 10_000
        return true
    }
    @discardableResult func hideHidden() -> Bool {
        guard canOperate, isEnabled else { return false }
        cancelSessionRecovery()
        unrestrictedActivation = false
        temporaryBundles = []
        hasTemporaryReveal = false
        if usesAssessment { return requestNative(expanded: false) }
        guard validateDividerOrder() else { return false }
        isSetupMode = false
        hiddenExpanded = false
        hiddenDivider?.length = 10_000
        alwaysDivider?.length = 10_000
        return true
    }
    func updateNativeContext(items: [MenuBarItem], settings: BarPilotSettings) {
        nativeItems = items
        nativeSettings = settings
        guard canOperate else { return }
        if usesAssessment, isEnabled, !runtime.accessibilityTrusted() || !competingManagers.isEmpty {
            disable()
            issue = L10n.text("權限已撤回或另一個管理器已開啟，已解除隱藏並停用管理。")
            return
        }
        guard usesAssessment, isEnabled, !isSetupMode, !isApplying, !isRecoveringSession, !unrestrictedActivation else {
            return
        }
        let next = nativePolicy(expanded: hiddenExpanded)
        if next != lastPolicy { _ = requestNative(expanded: hiddenExpanded) }
    }
    private func nativePolicy(expanded: Bool) -> MenuBarAssessmentPolicy {
        MenuBarAssessmentPolicy.make(
            items: nativeItems, settings: nativeSettings,
            runningBundles: runtime.runningBundles(),
            ownBundle: Bundle.main.bundleIdentifier ?? "local.pakwingho.barpilot", expanded: expanded,
            temporaryReveals: temporaryBundles)
    }
    func preserveActivation(bundle: String, wasSetup: Bool, wasExpanded: Bool) async throws {
        guard canOperate else { throw CancellationError() }
        guard usesAssessment, isEnabled, !wasSetup else { return }
        temporaryBundles.insert(bundle)
        returnExpanded = wasExpanded
        hasTemporaryReveal = true
        try await applyNativePolicy(items: nativeItems, settings: nativeSettings, expanded: true)
    }
    func revealOnlyForActivation(bundle: String) async throws {
        guard canOperate else { throw CancellationError() }
        guard usesAssessment, isEnabled else { return }
        temporaryBundles = [bundle]
        returnExpanded = false
        hasTemporaryReveal = true
        if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
            let location = application.bundleURL,
            !MenuBarLaunchLocation.supportsAssessment(
                running: location, registered: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle))
        {
            // MenuBarAgent cannot reveal allowlisted apps on Work volumes. Release the assertion only
            // for this native menu interaction; the temporary-reveal lease restores the hidden policy.
            cancelNative()
            unrestrictedActivation = true
            isSetupMode = false
            hiddenExpanded = false
            return
        }
        unrestrictedActivation = false
        try await applyNativePolicy(items: nativeItems, settings: nativeSettings, expanded: false)
    }
    func endTemporaryReveal() {
        guard hasTemporaryReveal else { return }
        unrestrictedActivation = false
        temporaryBundles = []
        hasTemporaryReveal = false
        _ = requestNative(expanded: returnExpanded)
    }
    private func requestNative(expanded: Bool) -> Bool {
        guard canOperate, !isApplying else { return false }
        // Record accepted intent before the asynchronous service call, including a lock mid-call.
        isSetupMode = false
        hiddenExpanded = expanded
        nativeTask?.cancel()
        nativeTask = Task { @MainActor in
            do {
                try await applyNativePolicy(items: nativeItems, settings: nativeSettings, expanded: expanded)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, canOperate else { return }
                issue = L10n.text("選單列服務未準備好，會重試：%1$@", String(describing: error.localizedDescription))
                recoverSessionVisibility(expanded: expanded)
            }
        }
        return true
    }

    private func cancelSessionRecovery() {
        guard isRecoveringSession else { return }
        recoveryGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecoveringSession = false
        cancelNative()
    }

    private func recoverSessionVisibility(expanded: Bool) {
        cancelSessionRecovery()
        cancelNative()
        recoveryGeneration &+= 1
        let request = recoveryGeneration
        isRecoveringSession = true
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if recoveryGeneration == request {
                    isRecoveringSession = false
                    recoveryTask = nil
                }
            }
            var attempt = 0
            while !Task.isCancelled, canOperate, isEnabled, recoveryGeneration == request {
                // Retry service/reflow failures, never a revoked grant or changed installation.
                guard hasVerifiedLaunchLocation, runtime.accessibilityTrusted(), competingManagers.isEmpty,
                    runtime.capabilityError() == nil, runtime.systemItems() != nil
                else {
                    cancelNative()
                    issue = L10n.text("未能恢復隱藏：請檢查 BarPilot 安裝位置、輔助使用權限及其他選單列管理器。原有分類保留。")
                    return
                }
                do {
                    try await applyNativePolicy(items: nativeItems, settings: nativeSettings, expanded: expanded)
                    for delay in runtime.controlCheckDelays {
                        try await Task.sleep(for: delay)
                        guard !Task.isCancelled, canOperate, recoveryGeneration == request else { return }
                        if concealedBundles.isEmpty || controlIsReachable() {
                            issue = nil
                            // Reconcile any inventory changes that arrived during activation.
                            isRecoveringSession = false
                            updateNativeContext(items: nativeItems, settings: nativeSettings)
                            verifyControlSoon()
                            return
                        }
                    }
                    issue = L10n.text("選單列仍在恢復，會重試關螢幕前的開收狀態。")
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, canOperate, recoveryGeneration == request else { return }
                    issue = L10n.text("選單列服務仍在恢復，會自動重試：%1$@", String(describing: error.localizedDescription))
                }
                // Keep the control available while waiting without entering expanded setup mode.
                cancelNative()
                restoreControl?()
                let delays = runtime.recoveryDelays
                let delay = delays.isEmpty ? Duration.seconds(30) : delays[min(attempt, delays.count - 1)]
                attempt = min(attempt + 1, delays.count)
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func applyNativePolicy(items: [MenuBarItem], settings: BarPilotSettings, expanded: Bool) async throws {
        guard !Task.isCancelled, canOperate else { throw CancellationError() }
        guard hasVerifiedLaunchLocation else {
            cancelNative()
            throw MenuBarOperationError(message: L10n.text("BarPilot 安裝登記已改變，已展開全部圖示；請重新開啟應用程式內的安裝版。"))
        }
        guard usesAssessment, isEnabled, runtime.accessibilityTrusted(), competingManagers.isEmpty else {
            cancelNative()
            throw MenuBarOperationError(message: L10n.text("選單列管理已停用、權限已撤回或另一個管理器正在運行。"))
        }
        nativeItems = items
        nativeSettings = settings
        let policy = nativePolicy(expanded: expanded)
        if lastPolicy == policy, !isApplying {
            isSetupMode = false
            hiddenExpanded = expanded
            return
        }
        cancelNative(cancelTask: false)
        let request = generation.advance()
        if policy.concealedBundles.isEmpty {
            lastPolicy = policy
            isSetupMode = false
            hiddenExpanded = expanded
            return
        }
        guard let systems = runtime.systemItems() else {
            throw MenuBarOperationError(message: L10n.text("未能確認系統圖示白名單，已取消隱藏以保留時鐘及控制中心。"))
        }
        isApplying = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion = continuation
                let activationTimeout = runtime.activationTimeout
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: activationTimeout) } catch { return }
                    guard let self, generation.accepts(request) else { return }
                    guard canOperate else {
                        cancelNative(cancelTask: false)
                        return
                    }
                    cancelNative(
                        cancelTask: false, error: MenuBarOperationError(message: L10n.text("macOS 隱藏服務未有回應，請稍後重試。")))
                }
                runtime.assessment.activate(systems, policy.allowedBundles) {
                    [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, generation.accepts(request) else { return }
                        guard canOperate else {
                            cancelNative(cancelTask: false)
                            return
                        }
                        timeout?.cancel()
                        timeout = nil
                        let pending = completion
                        completion = nil
                        isApplying = false
                        if let error {
                            runtime.assessment.invalidate()
                            lastPolicy = nil
                            concealedBundles = []
                            pending?.resume(throwing: error)
                        } else {
                            lastPolicy = policy
                            concealedBundles = policy.concealedBundles
                            isSetupMode = false
                            hiddenExpanded = expanded
                            verifyControlSoon()
                            issue = policy.mixedOwners.isEmpty ? nil : L10n.text("同一 App 的多個圖示分類不同，已保留顯示；重新選擇分類會一齊套用。")
                            pending?.resume()
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                updateNativeContext(items: nativeItems, settings: nativeSettings)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, generation.accepts(request) else { return }
                cancelNative(cancelTask: false)
            }
        }
    }
    private func cancelNative(cancelTask: Bool = true, error: Error = CancellationError()) {
        controlCheckTask?.cancel()
        controlCheckTask = nil
        if cancelTask {
            nativeTask?.cancel()
            nativeTask = nil
        }
        generation.advance()
        timeout?.cancel()
        timeout = nil
        runtime.assessment.invalidate()
        let pending = completion
        completion = nil
        pending?.resume(throwing: error)
        isApplying = false
        concealedBundles = []
        lastPolicy = nil
    }
    private func validateDividerOrder() -> Bool {
        guard let hidden = quartzFrame(hiddenDivider), let always = quartzFrame(alwaysDivider),
            let control = quartzFrame(controlItem), hidden.maxX <= control.minX + 1,
            always.maxX < hidden.maxX - 1, abs(hidden.midY - control.midY) < 8
        else {
            showAllForSetup()
            issue = L10n.text("分隔線未按正確次序，已展開全部避免遮住控制圖示。按住 ⌘：鎖在左、箭嘴在中、BarPilot 控制圖示在右。⌃⌥B → 設定可隨時停用管理。")
            return false
        }
        issue = nil
        return true
    }
    var dividerFrames: (hidden: CGRect, always: CGRect)? {
        guard let hidden = quartzFrame(hiddenDivider), let always = quartzFrame(alwaysDivider),
            hidden.width < 100, always.width < 100
        else { return nil }
        return (hidden, always)
    }
    var controlFrame: CGRect? { quartzFrame(controlItem) }
    func verifyControlSoon() {
        guard canOperate, usesAssessment, isEnabled, !isRecoveringSession, !concealedBundles.isEmpty else { return }
        controlCheckTask?.cancel()
        let request = generation.value
        let delays = runtime.controlCheckDelays
        controlCheckTask = Task { @MainActor [weak self] in
            for (index, delay) in delays.enumerated() {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, canOperate, generation.accepts(request), isEnabled, !isSetupMode else { return }
                guard controlIsReachable() else {
                    guard canOperate else { return }
                    // MenuBarAgent animates and replaces the hosted status-item scene during reflow.
                    if index < delays.count - 1 { continue }
                    restoreControl?()
                    // A hosted control can disappear briefly after a late MenuBarAgent rebuild.
                    // Release the assertion for reachability, but retain the user's expansion state.
                    recoverSessionVisibility(expanded: hiddenExpanded)
                    return
                }
            }
        }
    }
    private func controlIsReachable() -> Bool {
        if let reachable = runtime.controlReachable { return reachable() }
        guard controlItem?.isVisible == true, let button = controlItem?.button,
            !button.isHiddenOrHasHiddenAncestor, let frame = controlFrame,
            frame.width > 0, frame.width < 100,
            MenuBarDisplays.current.contains(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
        else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(frame.midX), Float(frame.midY), &hit) == .success,
            let hit
        else { return false }
        var owner: pid_t = -1
        guard AXUIElementGetPid(hit, &owner) == .success, owner == getpid() else { return false }
        var identifier: CFTypeRef?
        return AXUIElementCopyAttributeValue(hit, kAXIdentifierAttribute as CFString, &identifier) == .success
            && (identifier as? String) == "barpilot.status"
    }
    private func quartzFrame(_ item: NSStatusItem?) -> CGRect? {
        guard let button = item?.button, let window = button.window, window.isVisible else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let originHeight =
            NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.screens.first?.frame
            .maxY ?? 0
        return CGRect(x: rect.minX, y: originHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    func move(_ item: MenuBarItem, to destination: CGPoint, beforeDrag: (() throws -> Void)? = nil) async throws {
        guard canOperate else { throw CancellationError() }
        guard !usesAssessment else {
            throw MenuBarOperationError(message: L10n.text("macOS 27 排序需要選單列設定檔授權，未有改用滑鼠拖動。"))
        }
        guard isEnabled, !moving else { throw MenuBarOperationError(message: L10n.text("請先啟用管理，並等上一個移動完成。")) }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw MenuBarOperationError(message: L10n.text("移動圖示需要輔助使用權限及系統事件操作許可。"))
        }
        guard competingManagers.isEmpty else { throw MenuBarOperationError(message: L10n.text("另一個選單列管理器正在運行，移動已暫停。")) }
        guard let frame = item.frame, frame.width > 1, frame.width < 240, frame.height > 1, frame.height < 64,
            abs(frame.midY - destination.y) < 8
        else {
            throw MenuBarOperationError(message: L10n.text("圖示未在同一條可見選單列，請展開全部圖示並重新整理後再移動。"))
        }
        let originHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? 0
        let menuRegions = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: originHeight - screen.frame.maxY, width: screen.frame.width, height: 64)
        }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        guard menuRegions.contains(where: { $0.contains(start) && $0.contains(destination) }),
            topWindowOwner(at: start) == item.pid,
            !CGEventSource.buttonState(.combinedSessionState, button: .left),
            CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskShift, .maskAlternate])
                .isEmpty,
            let cursor = CGEvent(source: nil)?.location,
            let source = CGEventSource(stateID: .hidSystemState)
        else { throw MenuBarOperationError(message: L10n.text("移動暫停：圖示被遮擋、位置不可見或你正在操作滑鼠。請放開按鍵後再試。")) }
        try beforeDrag?()
        moving = true
        var mouseIsDown = false
        defer {
            if mouseIsDown { postMouse(.leftMouseUp, at: destination, source: source, command: true) }
            postMouse(.mouseMoved, at: cursor, source: source, command: false)
            moving = false
        }
        postMouse(.leftMouseDown, at: start, source: source, command: true)
        mouseIsDown = true
        for step in 1...12 {
            try Task.checkCancellation()
            let fraction = CGFloat(step) / 12
            postMouse(
                .leftMouseDragged, at: CGPoint(x: start.x + (destination.x - start.x) * fraction, y: destination.y),
                source: source, command: true)
            try await Task.sleep(for: .milliseconds(20))
        }
        postMouse(.leftMouseUp, at: destination, source: source, command: true)
        mouseIsDown = false
        try await Task.sleep(for: .milliseconds(250))
    }
    private func postMouse(_ type: CGEventType, at point: CGPoint, source: CGEventSource, command: Bool) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        if command { event?.flags = .maskCommand }
        event?.post(tap: .cghidEventTap)
    }
    private func topWindowOwner(at point: CGPoint) -> Int32? {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for window in windows {
            if (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.cursorWindow)) { continue }
            guard (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point)
            else { continue }
            guard rect.height <= 64, (window[kCGWindowLayer as String] as? Int ?? 0) < NSWindow.Level.popUpMenu.rawValue
            else { return nil }
            return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        return nil
    }
    func restoreCursor(_ point: CGPoint) throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
            !CGEventSource.buttonState(.combinedSessionState, button: .left),
            MenuBarDisplays.current.contains(where: { $0.frame.contains(point) }),
            let source = CGEventSource(stateID: .hidSystemState)
        else { throw MenuBarOperationError(message: L10n.text("請放開滑鼠並確認原有螢幕仍連接，然後再還原游標。")) }
        postMouse(.mouseMoved, at: point, source: source, command: false)
    }
}
