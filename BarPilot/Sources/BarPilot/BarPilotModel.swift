import AppKit
import BarPilotCore
import Combine

@MainActor final class BarPilotModel: ObservableObject {
    @Published private(set) var settings = BarPilotSettings()
    @Published private(set) var items: [MenuBarItem] = []
    @Published var notice: String?
    @Published private(set) var isWorking = false
    @Published var query = ""
    @Published var selectedTab = 0
    @Published var recoveryHotkeyAvailable = false
    @Published var selectedDisplayIdentifier: String?
    @Published var selectedVisibility: MenuBarVisibility?
    @Published private(set) var controlIsPinned = false
    @Published var overflowVisible = false
    @Published private(set) var pendingMove: MenuBarMoveJournalEntry?
    @Published private(set) var presentation: MenuBarPresentationSnapshot?
    let directory: URL
    let manager = MenuBarManager()
    let inventory = MenuBarInventoryService()
    let positions: MenuBarPositionService
    var bringMainWindow: (() -> Void)?
    var showShelfAction: (() -> Void)?
    var showWorkspaceAction: (() -> Void)?
    var showProShelfAction: (() -> Void)?
    var restoreStatusIconAction: (() -> Void)?
    var revealSettingsDidChange: (() -> Void)?
    var manuallyHidden: (() -> Void)?
    var revealOverflowIfNeeded: (() -> Bool)?
    var showOverflowAction: (() -> Void)?
    var hideOverflowAction: (() -> Void)?
    private let store: BarPilotSettingsStore
    private let journal: MenuBarMoveJournal
    private let presentationStore: MenuBarPresentationStore
    private var readOnlySettings = false
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var controlPinTask: Task<Void, Never>?
    private var lastControlPinAttempt: String?
    private var displayLayoutTask: Task<Void, Never>?
    private var attemptedDisplaySignature: String?
    private var scheduledDisplaySignature: String?
    @Published var displayLayoutStatus = ""
    @Published var displayLayoutsVisible = false
    private let controlID = "barpilot.status"

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarPilot", isDirectory: true)
        store = BarPilotSettingsStore(directory: self.directory)
        journal = MenuBarMoveJournal(directory: self.directory)
        presentationStore = MenuBarPresentationStore(directory: self.directory)
        positions = MenuBarPositionService(directory: self.directory)
        do { settings = try store.load() } catch {
            readOnlySettings = true
            notice = error.localizedDescription
        }
        do {
            pendingMove = try journal.pending()
            if pendingMove != nil { notice = L10n.text("上次移動未完成。原布局已保留；請先確認復原紀錄。") }
        } catch { notice = L10n.text("移動紀錄無法讀取，未有覆蓋：%1$@", String(describing: error.localizedDescription)) }
        do {
            presentation = try presentationStore.load()
            if presentation != nil, pendingMove == nil { notice = L10n.text("保留了簡報前布局；可明確選擇還原，未有在啟動時移動圖示。") }
        } catch { notice = L10n.text("簡報布局無法讀取，原有檔案未有覆蓋。") }
        inventory.savedOwnIdentifiers = MenuBarIdentity.savedOwnStatusIdentifiers(in: settings)
        manager.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        manager.$isRecoveringSession.removeDuplicates().dropFirst().filter { !$0 }.sink { [weak self] _ in
            Task { @MainActor in
                self?.scheduleControlPin()
                self?.scheduleDisplayLayout()
            }
        }.store(in: &subscriptions)
        inventory.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        positions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleDisplayLayout() }.store(in: &subscriptions)
    }
    var availableDisplays: [BarPilotDisplay] { MenuBarDisplays.current }
    var sessionIsActive: Bool { !manager.sessionSuspended && MenuBarDesktopSession.isInteractive }
    func suspendForSession() {
        displayLayoutTask?.cancel()
        displayLayoutTask = nil
        scheduledDisplaySignature = nil
        controlPinTask?.cancel()
        controlPinTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        manager.suspendForSession()
        hideOverflowAction?()
    }
    func resumeAfterSession() async {
        let remembered = items
        await inventory.refresh()
        guard !Task.isCancelled, MenuBarDesktopSession.isInteractive else { return }
        items = MenuBarOverflow.mergingVisibleInventory(
            inventory.items, remembered: remembered, concealedOwners: manager.concealedBundles,
            runningPIDs: Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))
        manager.resumeAfterSession(items: items, settings: settings)
        scheduleControlPin()
        scheduleDisplayLayout()
    }
    var filteredItems: [MenuBarItem] {
        MenuBarSearch.filter(items, query: query).filter {
            selectedDisplayIdentifier == nil || $0.displayIdentifier == selectedDisplayIdentifier
                || $0.displayIdentifier == nil
        }
    }
    func refresh() {
        guard sessionIsActive else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            let remembered = items
            await inventory.refresh()
            guard !Task.isCancelled, sessionIsActive else { return }
            if !inventory.hasPermission, manager.isEnabled {
                manager.disable()
                notice = L10n.text("輔助使用權限已撤回，已解除隱藏。重新授權後可再次啟用管理。")
            }
            items = MenuBarOverflow.mergingVisibleInventory(
                inventory.items, remembered: remembered,
                concealedOwners: manager.usesAssessment ? manager.concealedBundles : [],
                runningPIDs: Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))
            manager.updateNativeContext(items: items, settings: settings)
            scheduleControlPin()
            scheduleDisplayLayout()
        }
    }
    func scheduleControlPin(force: Bool = false) {
        // Moving our control emits a window-move notification. Do not cancel
        // the task that is currently applying and verifying that same move.
        guard sessionIsActive, !isWorking else { return }
        if force { lastControlPinAttempt = nil }
        controlPinTask?.cancel()
        controlPinTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await self?.pinControlIfNeeded()
        }
    }
    private func currentOrderingItem(_ id: String) throws -> MenuBarItem {
        guard id == controlID else { return try inventory.currentItem(id) }
        guard let frame = manager.controlFrame else {
            throw MenuBarOperationError(message: L10n.text("未能讀取控制圖示位置。"))
        }
        return MenuBarItem(
            id: controlID, bundleIdentifier: Bundle.main.bundleIdentifier ?? "local.pakwingho.barpilot",
            applicationName: "BarPilot", title: L10n.text("BarPilot 控制"),
            pid: ProcessInfo.processInfo.processIdentifier,
            frame: frame, canActivate: true, hasStableIdentity: true,
            displayIdentifier: MenuBarDisplays.current.first {
                $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
            }?.id,
            axIdentifier: try positions.controlPositionKey(), executableName: "BarPilot")
    }
    private func orderingContext(_ source: MenuBarItem) -> [MenuBarItem] {
        source.id == controlID ? inventory.items + [source] : inventory.items
    }
    private func pinControlIfNeeded() async {
        guard sessionIsActive, manager.usesAssessment, manager.isEnabled, manager.canVerifyControl,
            positions.isAuthorized, !isWorking,
            !manager.isApplying, !manager.isRecoveringSession, pendingMove == nil, positions.pending == nil,
            !positions.recoveryBlocked,
            !readOnlySettings, !CGEventSource.buttonState(.combinedSessionState, button: .left),
            let control = try? currentOrderingItem(controlID), let frame = control.frame
        else { return }
        guard let target = MenuBarControlOrder.target(for: control, in: items) else {
            controlIsPinned = true
            return
        }
        controlIsPinned = false
        let signature = "\(target.id):\(frame.minX.rounded()):\(target.frame?.minX.rounded() ?? 0)"
        guard signature != lastControlPinAttempt else { return }
        lastControlPinAttempt = signature
        isWorking = true
        defer {
            isWorking = false
            scheduleControlPin()
        }
        do {
            try await reorderNative(controlID, before: target.id, placement: .after)
            controlIsPinned = true
        } catch {
            notice = L10n.text("未能固定 ⋯ 位置：%1$@", String(describing: error.localizedDescription))
        }
    }
    func enableManagement() {
        guard !isWorking else { return }
        guard inventory.hasPermission else {
            inventory.requestPermission()
            notice = L10n.text("請先允許輔助使用，再按啟用管理。")
            return
        }
        do {
            try manager.enable()
            settings.managementEnabled = true
            persist()
            notice =
                manager.usesAssessment
                ? L10n.text("拖到常駐、收納或長期隱藏即可分類。同一 App 的圖示一齊隱藏；時鐘及控制中心保持顯示。排序需另外授權選單列設定檔。")
                : L10n.text("設置模式：按住 ⌘ 拖動原有圖示，或在下方拖到分類。完成後按「收起」。")
            manager.updateNativeContext(items: items, settings: settings)
            refresh()
        } catch { notice = error.localizedDescription }
    }
    func restoreManagementAtLaunch() {
        guard settings.managementEnabled, !readOnlySettings, inventory.hasPermission,
            manager.competingManagers.isEmpty, pendingMove == nil, positions.pending == nil, presentation == nil
        else { return }
        do {
            try manager.enable()
            // Start expanded so the controller is reachable before any saved hiding is applied.
            manager.updateNativeContext(items: items, settings: settings)
        } catch { notice = error.localizedDescription }
    }
    func disableManagement() {
        guard !isWorking else { return }
        hideOverflowAction?()
        manager.disable()
        settings.managementEnabled = false
        persist()
        notice = L10n.text("已停用管理，所有原有圖示保持顯示。")
    }
    func showHiddenItems() {
        guard sessionIsActive, !isWorking else { return }
        guard manager.isEnabled else {
            notice = L10n.text("請先啟用選單列管理。")
            bringMainWindow?()
            return
        }
        if revealOverflowIfNeeded?() == true { return }
        if !manager.showHidden() { notice = manager.issue }
        refresh()
    }
    func hideHiddenItems(automatic: Bool = false) {
        guard sessionIsActive, manager.isEnabled, !isWorking else { return }
        hideOverflowAction?()
        if !automatic { manuallyHidden?() }
        if !manager.hideHidden() { notice = manager.issue }
    }
    var revealSettings: MenuBarRevealSettings { (settings.reveal ?? MenuBarRevealSettings()).sanitized }
    var overflowMode: MenuBarOverflowMode { settings.overflowMode ?? .automatic }
    func updateOverflowMode(_ mode: MenuBarOverflowMode) {
        settings.overflowMode = mode
        persist()
    }
    func updateRevealSettings(_ update: (inout MenuBarRevealSettings) -> Void) {
        let wasPinned = revealSettings.keepOpen
        var value = revealSettings
        update(&value)
        settings.reveal = value.sanitized
        persist()
        revealSettingsDidChange?()
        if !wasPinned, value.keepOpen, manager.isEnabled, !manager.isSetupMode, !isWorking { showHiddenItems() }
    }
    func showAllItems() {
        guard manager.isEnabled, !isWorking else { return }
        hideOverflowAction?()
        manager.showAllForSetup()
        refresh()
    }
    func showShelf() { showShelfAction?() }
    func activate(_ id: String, revealOnlyOwner: Bool = false) async {
        guard sessionIsActive, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let wasSetup = manager.isSetupMode
        let wasExpanded = manager.hiddenExpanded
        let scopedReveal = revealOnlyOwner && manager.usesAssessment && manager.isEnabled
        let remembered = items
        do {
            if scopedReveal {
                guard let cached = items.first(where: { $0.id == id }) else {
                    throw MenuBarOperationError(message: L10n.text("圖示已退出，請重新整理後再試。"))
                }
                try await manager.revealOnlyForActivation(bundle: cached.bundleIdentifier)
                // MenuBarAgent replaces hosted AX elements after the assertion's completion callback.
                try await Task.sleep(for: .milliseconds(250))
            } else if manager.isEnabled {
                manager.showAllForSetup()
                try await Task.sleep(for: .milliseconds(200))
            }
            await inventory.refresh()
            guard !Task.isCancelled, sessionIsActive else { throw CancellationError() }
            items = MenuBarOverflow.mergingVisibleInventory(
                inventory.items, remembered: remembered,
                concealedOwners: manager.usesAssessment ? manager.concealedBundles : [],
                runningPIDs: Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))
            guard let item = items.first(where: { $0.id == id }) else {
                throw MenuBarOperationError(message: L10n.text("圖示已退出或改名，請選擇重新整理後的項目。"))
            }
            try await inventory.activate(item)
            notice = nil
            if manager.usesAssessment && !scopedReveal {
                // Preserve the real menu/popover. RevealController will reconceal only after interaction ends.
                manager.updateNativeContext(items: items, settings: settings)
                if wasSetup {
                    manager.showAllForSetup()
                } else {
                    try await manager.preserveActivation(
                        bundle: item.bundleIdentifier, wasSetup: wasSetup, wasExpanded: wasExpanded)
                }
            }
        } catch is CancellationError {
            manager.restoreVisibilityAfterOperation(setup: wasSetup, expanded: wasExpanded)
        } catch {
            notice = error.localizedDescription
            if manager.isEnabled, manager.usesAssessment {
                manager.updateNativeContext(items: items, settings: settings)
                if wasSetup {
                    manager.showAllForSetup()
                } else if wasExpanded {
                    _ = manager.showHidden()
                } else {
                    _ = manager.hideHidden()
                }
            }
            bringMainWindow?()
        }
    }
    func assign(_ id: String, to visibility: MenuBarVisibility) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await moveAndRecord(id, to: visibility)
            notice =
                manager.usesAssessment
                ? L10n.text("已將 App 的圖示分類為%1$@。", String(describing: visibility.title))
                : L10n.text("已移動至%1$@。", String(describing: visibility.title))
        } catch { notice = error.localizedDescription }
    }
    private func moveAndRecord(_ id: String, to visibility: MenuBarVisibility, expectedDisplay: String? = nil)
        async throws
    {
        if manager.usesAssessment {
            try await assignNativeOwner(id, to: visibility, expectedDisplay: expectedDisplay)
            return
        }
        guard manager.isEnabled else { throw MenuBarOperationError(message: L10n.text("請先啟用管理；分類會在驗證實際移動成功後儲存。")) }
        let wasSetup = manager.isSetupMode
        let wasExpanded = manager.hiddenExpanded
        manager.showAllForSetup()
        defer {
            if wasSetup {
                manager.showAllForSetup()
            } else if wasExpanded {
                manager.showHidden()
            } else {
                manager.hideHidden()
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        await inventory.refresh()
        items = inventory.items
        guard let item = items.first(where: { $0.id == id }), let dividers = manager.dividerFrames,
            let target = MenuBarMovePlan.target(
                visibility: visibility, hiddenDivider: dividers.hidden, alwaysDivider: dividers.always)
        else { throw MenuBarOperationError(message: L10n.text("分隔線位置未就緒。請在選單列把鎖放在箭嘴左邊，按 ⌘ 手動拖動，然後重新整理。")) }
        guard expectedDisplay == nil || item.displayIdentifier == expectedDisplay else {
            throw MenuBarOperationError(message: L10n.text("圖示不在布局指定的螢幕，原有布局已保留。請在該螢幕展開全部後再試。"))
        }
        let currentItem = try inventory.currentItem(id)
        guard let sourceFrame = currentItem.frame, let cursor = CGEvent(source: nil)?.location else {
            throw MenuBarOperationError(message: L10n.text("無法取得圖示或游標位置，未有移動。"))
        }
        if MenuBarMovePlan.classify(frame: sourceFrame, hiddenDivider: dividers.hidden, alwaysDivider: dividers.always)
            == visibility
        {
            var observed = settings.assignment(for: id)
            observed.visibility = visibility
            observed.positionVerified = true
            settings.assign(observed)
            try save()
            return
        }
        var entry = MenuBarMoveJournalEntry(
            itemID: id, desiredVisibility: visibility, displayIdentifier: item.displayIdentifier, cursor: cursor,
            sourceFrame: sourceFrame)
        try await manager.move(
            currentItem, to: target,
            beforeDrag: {
                try self.journal.begin(entry)
                self.pendingMove = entry
            })
        entry.stage = .nativeMoveFinished
        try journal.update(entry)
        pendingMove = entry
        await inventory.refresh()
        items = inventory.items
        guard let actual = items.first(where: { $0.id == id })?.frame, let after = manager.dividerFrames,
            MenuBarMovePlan.classify(frame: actual, hiddenDivider: after.hidden, alwaysDivider: after.always)
                == visibility
        else { throw MenuBarOperationError(message: L10n.text("macOS 沒有把這個圖示移到指定分類，配置未有改動。請按 ⌘ 手動拖動原有圖示；部分系統項目不可移動。")) }
        var assignment = settings.assignment(for: id)
        assignment.visibility = visibility
        assignment.positionVerified = true
        settings.assign(assignment)
        try save()
        entry.stage = .verified
        try journal.update(entry)
        try journal.complete(entry.id)
        pendingMove = nil
    }
    private func assignNativeOwner(_ id: String, to visibility: MenuBarVisibility, expectedDisplay: String?)
        async throws
    {
        guard manager.isEnabled, pendingMove == nil, let item = items.first(where: { $0.id == id }),
            let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated,
            app.bundleIdentifier == item.bundleIdentifier
        else { throw MenuBarOperationError(message: L10n.text("App 已退出或有未完成復原，請重新整理。")) }
        guard expectedDisplay == nil || item.displayIdentifier == expectedDisplay else {
            throw MenuBarOperationError(message: L10n.text("圖示不在布局指定的螢幕，未有改動。"))
        }
        guard visibility == .visible || !MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier) else {
            throw MenuBarOperationError(message: L10n.text("時鐘、控制中心及系統控制保持常駐；仍可另行排序。"))
        }
        let old = settings
        var proposed = settings
        let ownerIDs = Set(items.filter { $0.bundleIdentifier == item.bundleIdentifier }.map(\.id))
            .union(settings.assignments.filter { $0.id.hasPrefix(item.bundleIdentifier + "|") }.map(\.id))
        for ownerID in ownerIDs {
            var assignment = proposed.assignment(for: ownerID)
            assignment.visibility = visibility
            assignment.visibilityApplied = true
            proposed.assign(assignment)
        }
        let expanded = manager.isSetupMode ? true : manager.hiddenExpanded
        do {
            try await manager.applyNativePolicy(items: items, settings: proposed, expanded: expanded)
            settings = proposed
            try save()
        } catch {
            settings = old
            try? await manager.applyNativePolicy(items: items, settings: old, expanded: true)
            throw error
        }
        manager.updateNativeContext(items: items, settings: settings)
    }
    func reorder(_ id: String, before otherID: String, placement: MenuBarPlacement = .before) async {
        guard !isWorking, id != otherID else { return }
        if manager.usesAssessment {
            isWorking = true
            defer {
                isWorking = false
                scheduleControlPin()
            }
            do {
                try await reorderNative(id, before: otherID, placement: placement)
                notice = L10n.text("已驗證並儲存選單列排序。")
            } catch { notice = error.localizedDescription }
            return
        }
        isWorking = true
        let setup = manager.isSetupMode
        let expanded = manager.hiddenExpanded
        defer {
            isWorking = false
            if setup {
                manager.showAllForSetup()
            } else if expanded {
                manager.showHidden()
            } else {
                manager.hideHidden()
            }
        }
        do {
            guard manager.isEnabled else { throw MenuBarOperationError(message: L10n.text("請先啟用管理才可重新排序。")) }
            manager.showAllForSetup()
            try await Task.sleep(for: .milliseconds(250))
            await inventory.refresh()
            items = inventory.items
            guard let item = items.first(where: { $0.id == id }), items.contains(where: { $0.id == otherID })
            else { throw MenuBarOperationError(message: L10n.text("另一個圖示已退出，請重新整理。")) }
            let currentItem = try inventory.currentItem(id)
            let currentTarget = try inventory.currentItem(otherID)
            guard let sourceFrame = currentItem.frame, let targetFrame = currentTarget.frame,
                let cursor = CGEvent(source: nil)?.location
            else {
                throw MenuBarOperationError(message: L10n.text("無法取得游標位置。"))
            }
            var entry = MenuBarMoveJournalEntry(
                itemID: id, desiredVisibility: settings.assignment(for: id).visibility,
                displayIdentifier: item.displayIdentifier, cursor: cursor, sourceFrame: sourceFrame,
                beforeItemID: otherID, placement: placement)
            try await manager.move(
                currentItem,
                to: CGPoint(
                    x: placement == .before ? targetFrame.minX + 1 : targetFrame.maxX - 1, y: targetFrame.midY),
                beforeDrag: {
                    try self.journal.begin(entry)
                    self.pendingMove = entry
                })
            entry.stage = .nativeMoveFinished
            try journal.update(entry)
            pendingMove = entry
            await inventory.refresh()
            items = inventory.items
            guard let moved = items.first(where: { $0.id == id })?.frame,
                let destination = items.first(where: { $0.id == otherID })?.frame,
                placement.isSatisfied(source: moved, target: destination)
            else { throw MenuBarOperationError(message: L10n.text("macOS 未接受重新排序，請按 ⌘ 手動拖動原有圖示。")) }
            for (index, item) in items.enumerated() {
                var assignment = settings.assignment(for: item.id)
                assignment.order = index
                if let frame = item.frame, let dividers = manager.dividerFrames,
                    abs(frame.midY - dividers.hidden.midY) < 8
                {
                    assignment.visibility = MenuBarMovePlan.classify(
                        frame: frame, hiddenDivider: dividers.hidden, alwaysDivider: dividers.always)
                    assignment.positionVerified = true
                }
                settings.assign(assignment)
            }
            try save()
            entry.stage = .verified
            try journal.update(entry)
            try journal.complete(entry.id)
            pendingMove = nil
            notice = L10n.text("已重新排序並儲存。")
        } catch { notice = error.localizedDescription }
    }
    private func reorderNative(
        _ id: String, before otherID: String, placement: MenuBarPlacement = .before
    ) async throws {
        guard manager.isEnabled, pendingMove == nil, !readOnlySettings else {
            throw MenuBarOperationError(message: L10n.text("請先啟用管理並處理復原紀錄；設定無法讀取時不會改動位置。"))
        }
        let setup = manager.isSetupMode
        let expanded = manager.hiddenExpanded
        manager.showAllForSetup()
        defer {
            manager.updateNativeContext(items: items, settings: settings)
            manager.restoreVisibilityAfterOperation(setup: setup, expanded: expanded)
        }
        try await Task.sleep(for: .milliseconds(250))
        await inventory.refresh()
        guard !Task.isCancelled, sessionIsActive else { throw CancellationError() }
        items = inventory.items
        let source = try currentOrderingItem(id)
        let target = try inventory.currentItem(otherID)
        guard let a = source.frame, let b = target.frame,
            source.displayIdentifier == target.displayIdentifier, abs(a.midY - b.midY) < 8
        else { throw MenuBarOperationError(message: L10n.text("排序需要同一個螢幕上可辨識的圖示，未有跨螢幕或猜測移動。")) }
        guard manager.competingManagers.isEmpty, inventory.hasPermission else {
            throw MenuBarOperationError(message: L10n.text("權限或選單列管理器狀態已改變，排序已停止。"))
        }
        try positions.move(source, before: target, liveItems: orderingContext(source), placement: placement)
        try await verifyNativeOrder()
    }
    private func verifyNativeOrder() async throws {
        guard let pending = positions.pending else { throw PreferredPositionError.pendingMove }
        do {
            try await positions.waitForPreferenceReadback()
        } catch PreferredPositionError.unexpectedReadback {
            // System reflow may already have renumbered offsets. Completion
            // still requires fresh geometry and the same persisted key order.
        }
        for attempt in 0..<8 {
            try await Task.sleep(for: .milliseconds(250))
            guard sessionIsActive else { throw CancellationError() }
            if attempt == 6 {
                await inventory.refresh()
            } else {
                inventory.refreshGeometry()
            }
            items = inventory.items
            if let source = try? currentOrderingItem(pending.itemID),
                let target = try? inventory.currentItem(pending.beforeItemID),
                let a = source.frame, let b = target.frame,
                source.displayIdentifier == target.displayIdentifier,
                pending.displayIdentifier == nil || source.displayIdentifier == pending.displayIdentifier,
                (pending.placement ?? .before).isSatisfied(source: a, target: b)
            {
                do {
                    try positions.verifyCurrentBindings(source, before: target, liveItems: orderingContext(source))
                } catch PreferredPositionError.unexpectedReadback {
                    continue
                }
                for (index, item) in items.enumerated() {
                    var assignment = settings.assignment(for: item.id)
                    assignment.order = index
                    if item.id == source.id { assignment.positionVerified = true }
                    settings.assign(assignment)
                }
                try save()
                try positions.completeGeometryVerification()
                return
            }
        }
        throw MenuBarOperationError(message: L10n.text("位置偏好已寫入，但選單列尚未套用；復原紀錄保留，可重新驗證或還原原有位置。"))
    }
    func verifyPendingOrder() async {
        guard !isWorking, manager.isEnabled, positions.pending != nil else { return }
        isWorking = true
        let setup = manager.isSetupMode
        let expanded = manager.hiddenExpanded
        manager.showAllForSetup()
        defer {
            isWorking = false
            scheduleControlPin()
            manager.updateNativeContext(items: items, settings: settings)
            if setup {
                manager.showAllForSetup()
            } else if expanded {
                _ = manager.showHidden()
            } else {
                _ = manager.hideHidden()
            }
        }
        await inventory.refresh()
        items = inventory.items
        do {
            try await verifyNativeOrder()
            notice = L10n.text("排序已由選單列位置確認。")
        } catch { notice = error.localizedDescription }
    }
    func restorePendingOrder() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let id = positions.pending?.itemID
            try await positions.restoreOriginalPositions()
            if let id {
                var assignment = settings.assignment(for: id)
                assignment.positionVerified = false
                settings.assign(assignment)
                try save()
            }
            notice = positions.status
            refresh()
        } catch { notice = error.localizedDescription }
    }
    func setGroup(_ groupID: UUID?, for id: String) {
        guard groupID == nil || settings.groups.contains(where: { $0.id == groupID }) else { return }
        var assignment = settings.assignment(for: id)
        assignment.groupID = groupID
        settings.assign(assignment)
        persist()
    }
    func addGroup(_ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return }
        settings.groups.append(MenuBarGroup(name: name))
        persist()
    }
    func deleteGroup(_ id: UUID) {
        settings.groups.removeAll { $0.id == id }
        for index in settings.assignments.indices where settings.assignments[index].groupID == id {
            settings.assignments[index].groupID = nil
        }
        for preset in settings.presets.indices {
            for item in settings.presets[preset].assignments.indices
            where settings.presets[preset].assignments[item].groupID == id {
                settings.presets[preset].assignments[item].groupID = nil
            }
        }
        persist()
    }
    func savePreset(_ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return }
        guard manager.isEnabled, !isWorking, pendingMove == nil, positions.pending == nil else {
            notice = L10n.text("請先啟用管理並完成復原，才可儲存真實布局。")
            return
        }
        if manager.usesAssessment {
            Task {
                isWorking = true
                let setup = manager.isSetupMode
                let expanded = manager.hiddenExpanded
                defer {
                    isWorking = false
                    manager.updateNativeContext(items: items, settings: settings)
                    if setup {
                        manager.showAllForSetup()
                    } else if expanded {
                        _ = manager.showHidden()
                    } else {
                        _ = manager.hideHidden()
                    }
                }
                do {
                    let captured = try await captureNativeAssignments(display: selectedDisplayIdentifier)
                    settings.presets.append(
                        MenuBarPreset(name: name, assignments: captured, displayIdentifier: selectedDisplayIdentifier))
                    try save()
                    notice = L10n.text("已儲存「%1$@」的分類及可見次序。", String(describing: name))
                } catch { notice = error.localizedDescription }
            }
            return
        }
        Task {
            isWorking = true
            let setup = manager.isSetupMode
            let expanded = manager.hiddenExpanded
            manager.showAllForSetup()
            defer {
                isWorking = false
                if setup {
                    manager.showAllForSetup()
                } else if expanded {
                    manager.showHidden()
                } else {
                    manager.hideHidden()
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                await inventory.refresh()
                items = inventory.items
                guard let dividers = manager.dividerFrames, dividers.hidden.minX > dividers.always.minX else {
                    throw MenuBarOperationError(message: L10n.text("請先按 ⌘ 把鎖放到箭嘴左邊，再儲存布局。"))
                }
                let selected = items.filter {
                    selectedDisplayIdentifier == nil || $0.displayIdentifier == selectedDisplayIdentifier
                }
                guard !selected.isEmpty else {
                    throw MenuBarOperationError(message: L10n.text("這個螢幕沒有可讀取的圖示，未有建立空布局。"))
                }
                var assignments: [MenuBarAssignment] = []
                for (index, item) in selected.enumerated() {
                    guard let frame = item.frame, abs(frame.midY - dividers.hidden.midY) < 8 else {
                        throw MenuBarOperationError(message: L10n.text("所選螢幕的分隔線未能定位，未有儲存推測的分類。請選擇目前控制圖示所在的螢幕。"))
                    }
                    var assignment = settings.assignment(for: item.id)
                    assignment.visibility = MenuBarMovePlan.classify(
                        frame: frame, hiddenDivider: dividers.hidden, alwaysDivider: dividers.always)
                    assignment.positionVerified = true
                    assignment.order = index
                    assignments.append(assignment)
                }
                for assignment in assignments { settings.assign(assignment) }
                settings.presets.append(
                    MenuBarPreset(name: name, assignments: assignments, displayIdentifier: selectedDisplayIdentifier))
                try save()
                notice = L10n.text("已儲存「%1$@」的真實分類及次序。", String(describing: name))
            } catch { notice = error.localizedDescription }
        }
    }
    func deletePreset(_ id: UUID) {
        settings.presets.removeAll { $0.id == id }
        settings.displayLayoutRules?.removeAll { $0.presetID == id }
        persist()
    }
    func applyPreset(_ id: UUID) async {
        guard !isWorking, let preset = settings.presets.first(where: { $0.id == id }) else { return }
        guard manager.isEnabled else {
            notice = L10n.text("請先啟用管理，再套用布局。")
            bringMainWindow?()
            return
        }
        guard
            preset.displayIdentifier == nil || availableDisplays.contains(where: { $0.id == preset.displayIdentifier })
        else {
            notice = L10n.text("布局指定的螢幕已離線，布局與缺少的 App 配置仍保留。")
            return
        }
        if manager.usesAssessment {
            isWorking = true
            defer { isWorking = false }
            do { try await applyNativePreset(preset) } catch { notice = error.localizedDescription }
            return
        }
        let wasSetup = manager.isSetupMode
        let wasExpanded = manager.hiddenExpanded
        isWorking = true
        defer {
            isWorking = false
            if wasSetup {
                manager.showAllForSetup()
            } else if wasExpanded {
                manager.showHidden()
            } else {
                manager.hideHidden()
            }
        }
        var applied = 0
        var failures: [String] = []
        for assignment in preset.assignments.sorted(by: { $0.order > $1.order }) {
            do {
                try await moveAndRecord(
                    assignment.id, to: assignment.visibility, expectedDisplay: preset.displayIdentifier)
                setGroup(assignment.groupID, for: assignment.id)
                applied += 1
            } catch { failures.append(error.localizedDescription) }
        }
        if applied == preset.assignments.count, pendingMove == nil {
            do { try await restoreRelativeOrder(preset.assignments) } catch {
                failures.append(error.localizedDescription)
            }
        }
        notice =
            L10n.text(
                "布局「%1$@」：已套用 %2$@/%3$@ 項。", String(describing: preset.name), String(describing: applied),
                String(describing: preset.assignments.count)) + (failures.first.map { " \($0)" } ?? "")
    }
    func restorePendingCursor() {
        guard let pendingMove, !isWorking else { return }
        do {
            try manager.restoreCursor(pendingMove.cursor)
            notice = L10n.text("已還原游標；請確認圖示位置，再選擇保留或重試。")
        } catch { notice = error.localizedDescription }
    }
    func keepPendingMove() {
        guard let pendingMove, !isWorking else { return }
        do {
            try journal.complete(pendingMove.id)
            self.pendingMove = nil
            notice = L10n.text("已保留目前圖示位置；保存的布局未有覆蓋。")
            refresh()
        } catch { notice = error.localizedDescription }
    }
    func retryPendingMove() async {
        guard let pendingMove, !isWorking else { return }
        do {
            try journal.complete(pendingMove.id)
            self.pendingMove = nil
        } catch {
            notice = error.localizedDescription
            return
        }
        if let target = pendingMove.beforeItemID {
            await reorder(pendingMove.itemID, before: target, placement: pendingMove.placement ?? .before)
        } else {
            await assign(pendingMove.itemID, to: pendingMove.desiredVisibility)
        }
    }
    var commands: [MenuBarCommand] {
        let actions = MenuBarMainAction.allCases.filter { $0 != .restorePresentation || presentation != nil }.map {
            MenuBarCommand(
                id: "action:\($0.rawValue)", title: $0.title, subtitle: L10n.text("動作"), keywords: $0.keywords,
                kind: .action($0))
        }
        let presets = settings.presets.map {
            MenuBarCommand(id: "preset:\($0.id)", title: $0.name, subtitle: L10n.text("布局"), kind: .preset($0.id))
        }
        let currentIDs = Set(inventory.items.map(\.id))
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let remembered = items.filter {
            manager.usesAssessment && manager.concealedBundles.contains($0.bundleIdentifier)
                && running.contains($0.bundleIdentifier) && !currentIDs.contains($0.id)
        }
        let icons = (inventory.items + remembered).map {
            MenuBarCommand(
                id: "item:\($0.id)", title: $0.title,
                subtitle: L10n.text("圖示 · %1$@", String(describing: $0.applicationName))
                    + ($0.canActivate ? "" : L10n.text(" · 不支援 AXPress")),
                keywords: $0.bundleIdentifier, kind: .item($0.id))
        }
        return actions + presets + icons
    }
    func runCommand(_ command: MenuBarCommandKind) async {
        switch command {
        case .item(let id): await activate(id)
        case .preset(let id): await applyPreset(id)
        case .action(let action):
            switch action {
            case .settings: bringMainWindow?()
            case .workspace: showWorkspaceAction?()
            case .shelf: showProShelfAction?()
            case .showHidden: showHiddenItems()
            case .hideHidden: hideHiddenItems()
            case .showAll: showAllItems()
            case .presentation: await beginPresentation()
            case .restorePresentation: await restorePresentation()
            }
        }
    }
    func beginPresentation() async {
        guard !isWorking, manager.isEnabled, pendingMove == nil, positions.pending == nil, presentation == nil else {
            notice = L10n.text("請先啟用管理並完成復原；已有簡報布局時請先還原。")
            bringMainWindow?()
            return
        }
        isWorking = true
        defer { isWorking = false }
        let wasExpanded = manager.hiddenExpanded
        let wasSetup = manager.isSetupMode
        if manager.usesAssessment {
            do {
                let captured = try await captureNativeAssignments(display: nil)
                let snapshot = MenuBarPresentationSnapshot(
                    assignments: captured, wasExpanded: wasExpanded, wasSetupMode: wasSetup)
                try presentationStore.saveNew(snapshot)
                presentation = snapshot
                var proposed = settings
                for item in items where !MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier) {
                    var assignment = proposed.assignment(for: item.id)
                    if assignment.visibility == .visible { assignment.visibility = .hidden }
                    assignment.visibilityApplied = true
                    proposed.assign(assignment)
                }
                try await manager.applyNativePolicy(items: items, settings: proposed, expanded: false)
                settings = proposed
                try save()
                notice = L10n.text("簡報模式已收起一般 App 圖示；時鐘、控制中心及還原入口保持顯示。原有布局已保存。")
            } catch {
                manager.showAllForSetup()
                notice = error.localizedDescription
            }
            return
        }
        do {
            manager.showAllForSetup()
            try await Task.sleep(for: .milliseconds(250))
            await inventory.refresh()
            items = inventory.items
            guard let dividers = manager.dividerFrames, dividers.hidden.minX > dividers.always.minX else {
                throw MenuBarOperationError(message: L10n.text("請先完成分隔線設置。"))
            }
            var assignments: [MenuBarAssignment] = []
            for (index, item) in items.enumerated() {
                guard let frame = item.frame, abs(frame.midY - dividers.hidden.midY) < 8 else { continue }
                var assignment = settings.assignment(for: item.id)
                assignment.visibility = MenuBarMovePlan.classify(
                    frame: frame, hiddenDivider: dividers.hidden, alwaysDivider: dividers.always)
                assignment.order = index
                assignment.positionVerified = true
                assignments.append(assignment)
            }
            let snapshot = MenuBarPresentationSnapshot(
                assignments: assignments, wasExpanded: wasExpanded, wasSetupMode: wasSetup)
            try presentationStore.saveNew(snapshot)
            presentation = snapshot
            var moved = 0
            var failures = 0
            for assignment in assignments.filter({ $0.visibility == .visible }).sorted(by: { $0.order < $1.order }) {
                do {
                    try await moveAndRecord(assignment.id, to: .hidden)
                    moved += 1
                } catch {
                    failures += 1
                    if pendingMove != nil { break }
                }
            }
            manager.hideHidden()
            notice = L10n.text(
                "簡報模式已收起 %1$@ 個常駐圖示；%2$@ 項未能移動。簡報前布局已保存，可明確還原。", String(describing: moved), String(describing: failures)
            )
        } catch {
            notice = error.localizedDescription
            manager.showAllForSetup()
        }
    }
    func restorePresentation() async {
        guard !isWorking, let snapshot = presentation, manager.isEnabled, pendingMove == nil else {
            notice = L10n.text("請先啟用管理並確認移動復原紀錄，再還原簡報布局。")
            bringMainWindow?()
            return
        }
        isWorking = true
        defer { isWorking = false }
        if manager.usesAssessment {
            do {
                let preset = MenuBarPreset(name: L10n.text("簡報前布局"), assignments: snapshot.assignments)
                try await applyNativePreset(preset)
                try presentationStore.finish(snapshot.id)
                presentation = nil
                if snapshot.wasSetupMode {
                    manager.showAllForSetup()
                } else if snapshot.wasExpanded {
                    _ = manager.showHidden()
                } else {
                    _ = manager.hideHidden()
                }
                notice = L10n.text("簡報前分類及次序已還原。")
            } catch {
                manager.showAllForSetup()
                notice = L10n.text("未完成的簡報布局仍保留：%1$@", String(describing: error.localizedDescription))
            }
            return
        }
        var restored = 0
        var failures: [String] = []
        for visibility in MenuBarVisibility.allCases {
            let assignments = snapshot.assignments.filter { $0.visibility == visibility }.sorted {
                visibility == .visible ? $0.order > $1.order : $0.order < $1.order
            }
            for assignment in assignments {
                do {
                    try await moveAndRecord(assignment.id, to: visibility)
                    restored += 1
                } catch {
                    failures.append(error.localizedDescription)
                    if pendingMove != nil { break }
                }
            }
            if pendingMove != nil { break }
        }
        if restored == snapshot.assignments.count {
            do { try await restoreRelativeOrder(snapshot.assignments) } catch {
                failures.append(error.localizedDescription)
            }
        }
        if restored == snapshot.assignments.count, failures.isEmpty {
            do {
                try presentationStore.finish(snapshot.id)
                presentation = nil
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty {
            manager.showAllForSetup()
        } else if snapshot.wasSetupMode {
            manager.showAllForSetup()
        } else if snapshot.wasExpanded {
            manager.showHidden()
        } else {
            manager.hideHidden()
        }
        notice =
            L10n.text(
                "簡報布局已還原 %1$@/%2$@ 項。", String(describing: restored), String(describing: snapshot.assignments.count))
            + (failures.first.map { L10n.text(" 未完成的布局仍保留：%1$@", String(describing: $0)) } ?? "")
    }
    private func restoreRelativeOrder(_ assignments: [MenuBarAssignment]) async throws {
        if manager.usesAssessment {
            let ordered = assignments.sorted { $0.order < $1.order }
            guard ordered.count > 1 else { return }
            for index in stride(from: ordered.count - 2, through: 0, by: -1) {
                await inventory.refresh()
                items = inventory.items
                let source = try inventory.currentItem(ordered[index].id)
                let target = try inventory.currentItem(ordered[index + 1].id)
                guard let a = source.frame, let b = target.frame, source.displayIdentifier == target.displayIdentifier
                else {
                    throw MenuBarOperationError(message: L10n.text("部分布局圖示不可見或不在同一個螢幕，布局仍保留。"))
                }
                if a.maxX <= b.minX + 1 { continue }
                try await reorderNative(source.id, before: target.id)
            }
            return
        }
        manager.showAllForSetup()
        try await Task.sleep(for: .milliseconds(250))
        for visibility in MenuBarVisibility.allCases {
            let ordered = assignments.filter { $0.visibility == visibility }.sorted { $0.order < $1.order }
            guard ordered.count > 1 else { continue }
            for index in stride(from: ordered.count - 2, through: 0, by: -1) {
                inventory.refreshGeometry()
                items = inventory.items
                let item = try inventory.currentItem(ordered[index].id)
                let next = try inventory.currentItem(ordered[index + 1].id)
                guard let frame = item.frame, let target = next.frame, let dividers = manager.dividerFrames,
                    abs(frame.midY - target.midY) < 8,
                    MenuBarMovePlan.classify(
                        frame: frame, hiddenDivider: dividers.hidden, alwaysDivider: dividers.always) == visibility,
                    MenuBarMovePlan.classify(
                        frame: target, hiddenDivider: dividers.hidden, alwaysDivider: dividers.always) == visibility
                else { throw MenuBarOperationError(message: L10n.text("部分圖示的排序未能驗證，簡報布局仍保留。")) }
                if frame.midX < target.midX { continue }
                guard let cursor = CGEvent(source: nil)?.location else {
                    throw MenuBarOperationError(message: L10n.text("未能取得游標位置。"))
                }
                var entry = MenuBarMoveJournalEntry(
                    itemID: item.id, desiredVisibility: visibility, displayIdentifier: item.displayIdentifier,
                    cursor: cursor, sourceFrame: frame, beforeItemID: next.id)
                try await manager.move(
                    item, to: CGPoint(x: target.minX + 1, y: target.midY),
                    beforeDrag: {
                        try self.journal.begin(entry)
                        self.pendingMove = entry
                    })
                entry.stage = .nativeMoveFinished
                try journal.update(entry)
                pendingMove = entry
                inventory.refreshGeometry()
                items = inventory.items
                guard let actual = try inventory.currentItem(item.id).frame,
                    let after = try inventory.currentItem(next.id).frame,
                    actual.midX < after.midX
                else { throw MenuBarOperationError(message: L10n.text("macOS 未接受排序還原，復原紀錄仍保留。")) }
                try journal.complete(entry.id)
                pendingMove = nil
            }
        }
        for (index, item) in items.enumerated() {
            var assignment = settings.assignment(for: item.id)
            assignment.order = index
            settings.assign(assignment)
        }
        try save()
    }
    private func captureNativeAssignments(display: String?) async throws -> [MenuBarAssignment] {
        manager.showAllForSetup()
        try await Task.sleep(for: .milliseconds(250))
        await inventory.refresh()
        items = inventory.items
        let selected = items.filter { display == nil || $0.displayIdentifier == display }
        guard !selected.isEmpty,
            selected.allSatisfy({ item in
                guard let frame = item.frame else { return false }
                return frame.width > 1 && frame.width < 240 && frame.height > 1 && frame.height < 64
            })
        else { throw MenuBarOperationError(message: L10n.text("布局包含未能讀取的位置，未有保存推測或空布局。")) }
        return selected.enumerated().map { index, item in
            var assignment = settings.assignment(for: item.id)
            if MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier) {
                assignment.visibility = .visible
            }
            assignment.order = index
            return assignment
        }
    }
    private func applyNativePreset(_ preset: MenuBarPreset) async throws {
        guard positions.pending == nil, !positions.recoveryBlocked, pendingMove == nil else {
            throw PreferredPositionError.pendingMove
        }
        let setup = manager.isSetupMode
        let expanded = manager.hiddenExpanded
        manager.showAllForSetup()
        defer {
            manager.updateNativeContext(items: items, settings: settings)
            manager.restoreVisibilityAfterOperation(setup: setup, expanded: expanded)
        }
        try await Task.sleep(for: .milliseconds(250))
        await inventory.refresh()
        guard !Task.isCancelled, sessionIsActive else { throw CancellationError() }
        items = inventory.items
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard
            preset.assignments.allSatisfy({ assignment in
                guard let item = byID[assignment.id] else { return false }
                return preset.displayIdentifier == nil || item.displayIdentifier == preset.displayIdentifier
            })
        else { throw MenuBarOperationError(message: L10n.text("布局有 App 或螢幕離線，原布局仍保留，未有套用不完整分類。")) }
        let owners = Dictionary(grouping: preset.assignments, by: { byID[$0.id]!.bundleIdentifier })
        guard owners.values.allSatisfy({ Set($0.map(\.visibility)).count == 1 }) else {
            throw MenuBarOperationError(message: L10n.text("布局將同一 App 的圖示設為不同分類，請重新儲存符合 macOS 27 的布局。"))
        }
        var proposed = settings
        for (bundle, assignments) in owners {
            let visibility = assignments[0].visibility
            guard visibility == .visible || !MenuBarAssessmentPolicy.protectedBundles.contains(bundle) else {
                throw MenuBarOperationError(message: L10n.text("布局包含要隱藏的系統控制，已取消套用。"))
            }
            for item in items where item.bundleIdentifier == bundle {
                var assignment = proposed.assignment(for: item.id)
                assignment.visibility = visibility
                assignment.visibilityApplied = true
                if let saved = assignments.first(where: { $0.id == item.id }) {
                    assignment.groupID = saved.groupID
                    assignment.order = saved.order
                }
                proposed.assign(assignment)
            }
        }
        let old = settings
        settings = proposed
        do { try save() } catch {
            settings = old
            throw error
        }
        // Order is verified separately. A failed order keeps the saved preset and any recovery journal.
        try await restoreRelativeOrder(preset.assignments)
        try await manager.applyNativePolicy(items: items, settings: proposed, expanded: expanded)
        notice = L10n.text("已套用「%1$@」分類並驗證次序。", String(describing: preset.name))
    }
    private func save() throws {
        guard !readOnlySettings else {
            throw MenuBarOperationError(
                message: L10n.text("原設定檔無法讀取，為保留資料，未有寫入。請檢查 %1$@。", String(describing: store.url.path)))
        }
        try store.save(settings)
    }
    private func persist() {
        do { try save() } catch { notice = L10n.text("未能儲存：%1$@", String(describing: error.localizedDescription)) }
    }
    func setAutomaticDisplayLayouts(_ enabled: Bool) {
        let previous = settings
        settings.automaticDisplayLayouts = enabled
        do { try save() } catch {
            settings = previous
            notice = error.localizedDescription
            return
        }
        attemptedDisplaySignature = nil
        displayLayoutTask?.cancel()
        displayLayoutTask = nil
        scheduledDisplaySignature = nil
        if enabled { scheduleDisplayLayout() }
    }
    func bindCurrentDisplays(to presetID: UUID) {
        let previous = settings
        let displays = availableDisplays.map(\.id)
        var rules = settings.displayLayoutRules ?? []
        rules.removeAll { $0.matches(displays) }
        rules.append(.init(displayIDs: displays, presetID: presetID))
        settings.displayLayoutRules = rules
        do {
            try save()
            attemptedDisplaySignature = DisplayLayoutRule.signature(displays)
            displayLayoutStatus = L10n.text("已記住目前螢幕組合；下次切換至此組合時套用。")
        } catch {
            settings = previous
            notice = error.localizedDescription
        }
        // Binding a layout only saves the rule. Applying remains explicit or on the next display change.
    }
    func removeDisplayRule(_ id: UUID) {
        let previous = settings
        settings.displayLayoutRules?.removeAll { $0.id == id }
        do { try save() } catch {
            settings = previous
            notice = error.localizedDescription
        }
    }
    func scheduleDisplayLayout() {
        guard settings.automaticDisplayLayouts == true, sessionIsActive, !readOnlySettings else { return }
        let displays = availableDisplays.map(\.id)
        let signature = DisplayLayoutRule.signature(displays)
        guard signature != attemptedDisplaySignature, signature != scheduledDisplaySignature else { return }
        displayLayoutTask?.cancel()
        scheduledDisplaySignature = signature
        displayLayoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            guard let self else { return }
            defer {
                if scheduledDisplaySignature == signature {
                    scheduledDisplaySignature = nil
                    displayLayoutTask = nil
                }
            }
            for _ in 0..<6 {
                guard !Task.isCancelled, sessionIsActive,
                    signature == DisplayLayoutRule.signature(availableDisplays.map(\.id))
                else { return }
                if !isWorking && !manager.isApplying && !manager.isRecoveringSession { break }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
            guard !Task.isCancelled, !isWorking, !manager.isApplying, !manager.isRecoveringSession else {
                displayLayoutStatus = L10n.text("布局操作仍在進行，今次未自動切換；可從布局選單手動套用。")
                return
            }
            guard let rule = settings.displayLayoutRules?.first(where: { $0.matches(displays) }) else {
                attemptedDisplaySignature = signature
                displayLayoutStatus = L10n.text("目前螢幕組合未有指定布局。")
                return
            }
            guard manager.isEnabled, inventory.hasPermission,
                !manager.usesAssessment || positions.isAuthorized,
                pendingMove == nil, positions.pending == nil, !positions.recoveryBlocked, presentation == nil,
                !CGEventSource.buttonState(.combinedSessionState, button: .left)
            else {
                displayLayoutStatus = L10n.text("未自動套用：請先啟用管理、授權排序，並完成待處理的復原操作。")
                return
            }
            attemptedDisplaySignature = signature
            await applyPreset(rule.presetID)
            displayLayoutStatus = notice ?? L10n.text("已處理螢幕布局。")
        }
    }
    func hiddenReason(for item: MenuBarItem) -> String {
        MenuBarHiddenReason.explain(
            visibility: settings.assignment(for: item.id).visibility, enabled: manager.isEnabled,
            permission: inventory.hasPermission,
            protected: manager.usesAssessment
                && MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier),
            setup: manager.isSetupMode, expanded: manager.hiddenExpanded, temporary: manager.hasTemporaryReveal,
            concealed: manager.concealedBundles.contains(item.bundleIdentifier), frameAvailable: item.frame != nil,
            unavailable: item.unavailableReason)
    }
}
