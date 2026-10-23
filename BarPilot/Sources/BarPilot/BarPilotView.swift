import AppKit
import BarPilotCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct BarPilotMainView: View {
    @ObservedObject var model: BarPilotModel
    @State private var group: UUID?
    @State private var groupName = ""
    @State private var presetName = ""
    @State private var newGroup = false
    @State private var newPreset = false
    @State private var behaviorExpanded = false
    @State private var draggingID: String?
    @State private var dropTarget: BarPilotItemDropTarget?
    @State private var reasonItemID: String?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Label("BarPilot", systemImage: "menubar.rectangle").font(.title2.bold())
                Button {
                    model.selectedTab = 0
                    group = nil
                    model.selectedVisibility = nil
                } label: {
                    Label(L10n.text("選單列"), systemImage: "square.grid.2x2")
                }
                Button {
                    model.showWorkspaceAction?()
                } label: {
                    Label(L10n.text("NotchHub 工作台"), systemImage: "arrow.up.forward.app")
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text(L10n.text("分組")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                newGroup = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                        ForEach(model.settings.groups) { item in
                            Button {
                                model.selectedTab = 0
                                group = item.id
                            } label: {
                                Label(item.name, systemImage: "folder")
                            }
                            .contextMenu {
                                Button(L10n.text("刪除分組"), role: .destructive) {
                                    model.deleteGroup(item.id)
                                    if group == item.id { group = nil }
                                }
                            }
                        }
                        Divider()
                        HStack {
                            Text(L10n.text("布局")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                newPreset = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                        ForEach(model.settings.presets) { preset in
                            Button {
                                Task { await model.applyPreset(preset.id) }
                            } label: {
                                Label(preset.name, systemImage: "rectangle.3.group")
                            }
                            .disabled(model.isWorking)
                            .contextMenu {
                                Button(L10n.text("刪除布局"), role: .destructive) { model.deletePreset(preset.id) }
                            }
                        }
                        Button {
                            model.displayLayoutsVisible = true
                        } label: {
                            Label(L10n.text("螢幕自動布局…"), systemImage: "display.2")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
                Button(L10n.text("快速搜尋 · ⌃⌥B"), action: model.showShelf)
                Button(L10n.text("顯示頂部圖示")) { model.restoreStatusIconAction?() }
                    .accessibilityIdentifier("barpilot.show-status")
                Text(model.recoveryHotkeyAvailable ? L10n.text("救援捷徑 · ⌃⌥⇧B") : L10n.text("救援捷徑被佔用；由 Finder 再開 App"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("barpilot.recovery-hotkey")
                Text(L10n.text("本機管理 · 不需帳戶")).font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(20).frame(width: 220).frame(maxHeight: .infinity)
            .background(.thinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                inventoryContents
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 610)
        .sheet(isPresented: $model.displayLayoutsVisible) { DisplayLayoutsView(model: model) }
        .alert(L10n.text("新增分組"), isPresented: $newGroup) {
            TextField(L10n.text("分組名稱"), text: $groupName)
            Button(L10n.text("新增")) {
                model.addGroup(groupName)
                groupName = ""
            }
            Button(L10n.text("取消"), role: .cancel) {}
        }
        .alert(L10n.text("儲存目前布局"), isPresented: $newPreset) {
            TextField(L10n.text("布局名稱"), text: $presetName)
            Button(L10n.text("儲存")) {
                model.savePreset(presetName)
                presetName = ""
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("保存已設定的分類、分組和次序；套用時只移動仍在運行的圖示。"))
        }
        .onChange(of: model.positions.isAuthorized) { _, authorized in
            if authorized { model.scheduleControlPin(force: true) }
        }
    }
    private var inventoryContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        group.flatMap { id in model.settings.groups.first { $0.id == id }?.name } ?? L10n.text("你的選單列")
                    ).font(
                        .title2.bold())
                    Text(model.inventory.state.message).font(.callout).foregroundStyle(.secondary)
                    Text(model.manager.backendDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.inventory.state == .loading { ProgressView().controlSize(.small) }
                Button(L10n.text("重新整理"), action: model.refresh).accessibilityIdentifier("barpilot.refresh")
            }
            if !model.inventory.hasPermission {
                HStack {
                    Image(systemName: "hand.raised").font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("連接選單列")).font(.headline)
                        Text(L10n.text("只讀取 App 提供的輔助使用項目；不錄製螢幕。")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("允許輔助使用")) {
                        model.inventory.requestPermission()
                        model.inventory.openPermissionSettings()
                    }
                    .accessibilityIdentifier("barpilot.permission")
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                if model.manager.isEnabled {
                    Label(
                        model.manager.isSetupMode ? L10n.text("設置模式") : L10n.text("管理已啟用"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Spacer()
                    Button(L10n.text("展開全部"), action: model.showAllItems)
                    Button(L10n.text("圖示列")) { model.showOverflowAction?() }
                        .disabled(model.isWorking || model.manager.isApplying)
                        .accessibilityIdentifier("barpilot.show-overflow")
                    Button(L10n.text("展開收納"), action: model.showHiddenItems)
                    Button(L10n.text("收起")) { model.hideHiddenItems() }
                    Button(L10n.text("停用"), action: model.disableManagement)
                } else {
                    Label(L10n.text("尚未改動任何圖示"), systemImage: "pause.circle")
                    Spacer()
                    Button(L10n.text("啟用管理"), action: model.enableManagement).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("barpilot.enable")
                }
            }.font(.callout)
            if model.manager.usesAssessment {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(model.positions.status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("barpilot.order-status")
                    Spacer()
                    if model.manager.isApplying { ProgressView().controlSize(.small) }
                    Button(
                        model.positions.isAuthorized ? L10n.text("重新授權") : L10n.text("授權排序"),
                        action: model.positions.requestAccess
                    )
                    .disabled(model.isWorking || model.manager.isApplying)
                    .accessibilityIdentifier("barpilot.order-access")
                }.padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                if let pending = model.positions.pending {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            pending.stage == .writeVerified ? L10n.text("位置已寫入，等待系統套用") : L10n.text("未完成排序，有原有位置紀錄"),
                            systemImage: "arrow.uturn.backward.circle"
                        ).font(.headline)
                        Text(L10n.text("寫入設定同選單列實際次序會分開驗證。其他偏好保留；還原時亦會先檢查有冇被改動。"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.text("重新驗證")) { Task { await model.verifyPendingOrder() } }
                                .disabled(model.isWorking || !model.manager.isEnabled)
                            Button(L10n.text("還原原有位置")) { Task { await model.restorePendingOrder() } }
                                .disabled(model.isWorking)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            DisclosureGroup(L10n.text("展開方式及簡報"), isExpanded: $behaviorExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(
                        L10n.text("圖示展開"),
                        selection: Binding(get: { model.overflowMode }, set: { model.updateOverflowMode($0) })
                    ) {
                        ForEach(MenuBarOverflowMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }
                    .font(.caption).frame(maxWidth: 340)
                    .accessibilityIdentifier("barpilot.overflow-mode")
                    HStack(spacing: 16) {
                        Toggle(
                            L10n.text("停在圖示展開"),
                            isOn: Binding(
                                get: { model.revealSettings.hoverReveal },
                                set: { value in
                                    model.updateRevealSettings {
                                        $0.hoverReveal = value
                                        if value { $0.automaticallyHide = true }
                                    }
                                }))
                        Toggle(
                            L10n.text("離開後收起"),
                            isOn: Binding(
                                get: { model.revealSettings.automaticallyHide },
                                set: { value in model.updateRevealSettings { $0.automaticallyHide = value } }))
                        Toggle(
                            L10n.text("保持展開"),
                            isOn: Binding(
                                get: { model.revealSettings.keepOpen },
                                set: { value in model.updateRevealSettings { $0.keepOpen = value } }))
                        Picker(
                            L10n.text("延遲"),
                            selection: Binding(
                                get: { model.revealSettings.hideDelaySeconds },
                                set: { value in model.updateRevealSettings { $0.hideDelaySeconds = value } })
                        ) {
                            ForEach([0.5, 1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) {
                                Text(L10n.text("%1$@ 秒", String(describing: $0.formatted()))).tag($0)
                            }
                        }.frame(maxWidth: 125)
                    }.font(.caption)
                    HStack {
                        if model.presentation == nil {
                            Button(L10n.text("簡報模式")) { Task { await model.beginPresentation() } }.disabled(
                                model.isWorking || !model.manager.isEnabled)
                            Text(L10n.text("先保存真實布局，再收起可移動圖示。")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label(L10n.text("簡報前布局已保留"), systemImage: "display")
                            Button(L10n.text("還原簡報前布局")) { Task { await model.restorePresentation() } }.disabled(
                                model.isWorking || !model.manager.isEnabled)
                        }
                    }
                }
            }.font(.callout)
            if let notice = model.manager.issue ?? model.notice {
                Text(notice).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("barpilot.notice")
            }
            if let pending = model.pendingMove {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("移動復原紀錄"), systemImage: "arrow.uturn.backward.circle").font(.headline)
                    Text(
                        L10n.text(
                            "%1$@ · 目標：%2$@ · 原有布局仍保留", String(describing: pending.createdAt.formatted()),
                            String(describing: pending.desiredVisibility.title))
                    ).font(
                        .caption)
                    HStack {
                        Button(L10n.text("還原游標"), action: model.restorePendingCursor).disabled(model.isWorking)
                        Button(L10n.text("保留目前位置"), action: model.keepPendingMove).disabled(model.isWorking)
                        Button(L10n.text("重試移動")) { Task { await model.retryPendingMove() } }.disabled(
                            model.isWorking || !model.manager.isEnabled)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 10) {
                Button {
                    model.selectedVisibility = nil
                } label: {
                    Label(L10n.text("全部 · %1$@", String(describing: baseItems.count)), systemImage: "square.grid.2x2")
                        .font(.callout.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(
                            model.selectedVisibility == nil
                                ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9).strokeBorder(
                                model.selectedVisibility == nil ? Color.accentColor : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("barpilot.filter.all")
                .accessibilityAddTraits(model.selectedVisibility == nil ? .isSelected : [])
                ForEach(MenuBarVisibility.allCases, id: \.self) { visibility in
                    BarPilotDropZone(
                        visibility: visibility,
                        count: baseItems.filter { effectiveVisibility($0) == visibility }.count,
                        enabled: model.manager.isEnabled && !model.isWorking && !model.manager.isApplying,
                        selected: model.selectedVisibility == visibility,
                        select: { model.selectedVisibility = visibility }
                    ) {
                        id in
                        draggingID = nil
                        dropTarget = nil
                        Task { await model.assign(id, to: visibility) }
                    }
                }
            }
            Text(
                model.manager.usesAssessment
                    ? L10n.text("按分類篩選；拖拉左邊手柄排位，藍線標示插入位置。拖入分類可設定隱藏。")
                    : L10n.text("按分類篩選；拖拉左邊手柄排位，或拖入分類更改頂部位置。")
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("搜尋 App、圖示或名稱"), text: $model.query).textFieldStyle(.plain)
                    .accessibilityIdentifier("barpilot.filter.search")
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).help(L10n.text("清除搜尋")).accessibilityIdentifier("barpilot.filter.clear-search")
                }
                Picker(L10n.text("螢幕"), selection: $model.selectedDisplayIdentifier) {
                    Text(L10n.text("全部螢幕")).tag(String?.none)
                    ForEach(model.availableDisplays) { display in Text(display.name).tag(Optional(display.id)) }
                }.labelsHidden().frame(maxWidth: 170)
                Text(
                    L10n.text("%1$@ / %2$@ 項", String(describing: listItems.count), String(describing: baseItems.count))
                ).font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit().accessibilityIdentifier("barpilot.filter.count")
            }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            if model.items.isEmpty {
                ContentUnavailableView(
                    L10n.text("暫未讀到圖示"), systemImage: "menubar.rectangle",
                    description: Text(model.inventory.state.message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listItems.isEmpty {
                ContentUnavailableView(
                    L10n.text("此分類沒有符合的圖示"), systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(L10n.text("可切換「全部」或清除搜尋。")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(listItems) { item in
                            itemRow(item)
                        }
                    }
                }
                .accessibilityIdentifier("barpilot.items")
                .id(
                    BarPilotListScope(
                        query: model.query, visibility: model.selectedVisibility,
                        display: model.selectedDisplayIdentifier, group: group))
            }
            HStack {
                Label(
                    model.controlIsPinned ? L10n.text("⋯ 已固定在 App 最右側") : L10n.text("⋯ 控制圖示固定在 App 最右側"),
                    systemImage: "pin.fill")
                Spacer()
                if model.manager.usesAssessment && !model.controlIsPinned {
                    Button(L10n.text("固定位置")) { model.scheduleControlPin(force: true) }
                        .disabled(!model.manager.isEnabled || !model.positions.isAuthorized || model.isWorking)
                        .accessibilityIdentifier("barpilot.pin-control")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .help(L10n.text("控制圖示保持常駐，排列在其他 App 之後、右側系統圖示之前。"))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("barpilot.pinned-control")
        }
    }
    private var baseItems: [MenuBarItem] {
        MenuBarListFilter.items(
            model.items, settings: model.settings, query: model.query,
            display: model.selectedDisplayIdentifier, group: group, native: model.manager.usesAssessment)
    }
    private var listItems: [MenuBarItem] {
        baseItems.filter { model.selectedVisibility == nil || effectiveVisibility($0) == model.selectedVisibility }
    }
    private func effectiveVisibility(_ item: MenuBarItem) -> MenuBarVisibility {
        MenuBarListFilter.visibility(of: item, settings: model.settings, native: model.manager.usesAssessment)
    }
    private func itemRow(_ item: MenuBarItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(canDrag(item) ? Color.secondary : Color.secondary.opacity(0.3))
                .frame(width: 16, height: 20).contentShape(Rectangle())
                .help(dragHelp(item))
                .onDrag {
                    guard canDrag(item) else { return NSItemProvider() }
                    draggingID = item.id
                    menuBarDragLog.info("Started menu item drag")
                    return menuBarItemProvider(item.id)
                }
                .accessibilityLabel(L10n.text("拖拉排位"))
                .accessibilityIdentifier("barpilot.drag." + item.id)
            Image(
                nsImage: NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage(
                    systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)!
            )
            .resizable().scaledToFit().frame(width: 20, height: 20)
            HStack(spacing: 7) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if item.title.localizedCaseInsensitiveCompare(item.applicationName) != .orderedSame {
                    Text(item.applicationName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !item.hasStableIdentity {
                    Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                        .help(L10n.text("App 未提供固定圖示名稱；只有目前唯一圖示及唯一位置鍵才能自動排序。"))
                }
            }
            Spacer()
            Button {
                reasonItemID = item.id
            } label: {
                Image(systemName: "info.circle").font(.caption)
            }
            .buttonStyle(.plain).help(model.hiddenReason(for: item))
            .accessibilityLabel(L10n.text("圖示顯示／隱藏原因"))
            .popover(isPresented: Binding(get: { reasonItemID == item.id }, set: { if !$0 { reasonItemID = nil } })) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.applicationName).font(.headline)
                    Text(model.hiddenReason(for: item)).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(width: 310)
            }
            Text(
                model.manager.usesAssessment
                    ? (MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier)
                        ? L10n.text("系統常駐")
                        : effectiveVisibility(item).title)
                    : (model.settings.assignment(for: item.id).positionVerified == true
                        ? model.settings.assignment(for: item.id).visibility.title : L10n.text("未分類"))
            )
            .font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
            if model.manager.usesAssessment {
                Button {
                    moveOneStep(item, left: true)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help(L10n.text("向左一格")).disabled(!canMoveOneStep(item, left: true))
                .accessibilityIdentifier("barpilot.move-left." + item.id)
                Button {
                    moveOneStep(item, left: false)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help(L10n.text("向右一格")).disabled(!canMoveOneStep(item, left: false))
                .accessibilityIdentifier("barpilot.move-right." + item.id)
            }
            Menu {
                ForEach(MenuBarVisibility.allCases, id: \.self) { visibility in
                    Button(L10n.text("設為%1$@", String(describing: visibility.title))) {
                        Task { await model.assign(item.id, to: visibility) }
                    }
                    .disabled(
                        model.isWorking || model.manager.isApplying || !model.manager.isEnabled
                            || (model.manager.usesAssessment && visibility != .visible
                                && MenuBarAssessmentPolicy.protectedBundles.contains(item.bundleIdentifier))
                    )
                }
                Divider()
                Button(L10n.text("移出分組")) { model.setGroup(nil, for: item.id) }
                ForEach(model.settings.groups) { group in
                    Button(L10n.text("加入「%1$@」", String(describing: group.name))) {
                        model.setGroup(group.id, for: item.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
            Button(L10n.text("開啟")) { Task { await model.activate(item.id) } }.disabled(
                model.isWorking || !item.canActivate
            )
            .help(item.unavailableReason ?? L10n.text("透過 AXPress 開啟原有圖示"))
            .accessibilityIdentifier("barpilot.open." + item.id)
        }
        .controlSize(.small).padding(.horizontal, 10).frame(height: 32)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: dropTarget?.placement == .after ? .bottom : .top) {
            if dropTarget?.id == item.id {
                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [menuBarItemType],
            delegate: BarPilotItemDropDelegate(
                id: item.id, draggingID: $draggingID, target: $dropTarget,
                canAccept: { canDrop($0, on: item) },
                perform: { id, placement in
                    Task { await model.reorder(id, before: item.id, placement: placement) }
                })
        )
        .accessibilityElement(children: .contain).accessibilityIdentifier("barpilot.item.\(item.id)")
    }
    private func canDrag(_ item: MenuBarItem) -> Bool {
        model.manager.isEnabled && !model.isWorking && !model.manager.isApplying
            && model.pendingMove == nil && model.positions.pending == nil && !model.positions.recoveryBlocked
    }
    private func canDrop(_ sourceID: String, on target: MenuBarItem) -> Bool {
        guard sourceID != target.id, canDrag(target),
            let source = model.items.first(where: { $0.id == sourceID }),
            source.displayIdentifier == target.displayIdentifier
        else { return false }
        return !model.manager.usesAssessment
            || (model.positions.canResolve(source, liveItems: model.items)
                && model.positions.canResolve(target, liveItems: model.items))
    }
    private func dragHelp(_ item: MenuBarItem) -> String {
        guard canDrag(item) else { return L10n.text("啟用管理並處理未完成排序後，可拖拉排位或分類。") }
        if model.manager.usesAssessment, !model.positions.canResolve(item, liveItems: model.items) {
            return L10n.text("可拖入分類；這個圖示尚未有唯一位置資料，暫不能排序。")
        }
        return L10n.text("拖到另一行的上半或下半，放在該項目前或後；亦可拖入分類。")
    }
    private func neighbors(_ item: MenuBarItem) -> [MenuBarItem] {
        model.items.filter { $0.displayIdentifier == item.displayIdentifier }.sorted {
            ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0)
        }
    }
    private func canMoveOneStep(_ item: MenuBarItem, left: Bool) -> Bool {
        let ordered = neighbors(item)
        guard model.manager.isEnabled, !model.isWorking, !model.manager.isApplying,
            model.positions.pending == nil, model.positions.canResolve(item, liveItems: model.items),
            let index = ordered.firstIndex(where: { $0.id == item.id })
        else { return false }
        let neighbor = left ? index - 1 : index + 1
        return ordered.indices.contains(neighbor)
            && model.positions.canResolve(ordered[neighbor], liveItems: model.items)
    }
    private func moveOneStep(_ item: MenuBarItem, left: Bool) {
        let ordered = neighbors(item)
        guard canMoveOneStep(item, left: left), let index = ordered.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        if left {
            Task { await model.reorder(item.id, before: ordered[index - 1].id) }
        } else {
            Task { await model.reorder(ordered[index + 1].id, before: item.id) }
        }
    }
}

private struct BarPilotDropZone: View {
    let visibility: MenuBarVisibility
    let count: Int
    let enabled: Bool
    let selected: Bool
    let select: () -> Void
    let move: (String) -> Void
    @State private var targeted = false
    var body: some View {
        Button(action: select) {
            Label(
                "\(visibility.title) · \(count)",
                systemImage: visibility == .visible ? "eye" : visibility == .hidden ? "archivebox" : "lock"
            )
            .font(.callout.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(
                targeted || selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9).strokeBorder(
                    targeted || selected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("barpilot.filter." + visibility.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(enabled ? L10n.text("按一下篩選；拖入圖示更改分類") : L10n.text("按一下篩選；啟用管理後可拖入更改分類"))
        .onDrop(of: [menuBarItemType], isTargeted: $targeted) { providers in
            guard enabled else { return false }
            return readItemID(providers, action: move)
        }
    }
}

private func readItemID(_ providers: [NSItemProvider], action: @escaping (String) -> Void) -> Bool {
    guard let provider = providers.first, provider.hasItemConformingToTypeIdentifier(menuBarItemType.identifier)
    else { return false }
    _ = provider.loadDataRepresentation(forTypeIdentifier: menuBarItemType.identifier) { data, _ in
        guard let data, data.count < 4096, let value = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in action(value) }
    }
    return true
}

private let menuBarDragLog = Logger(subsystem: "local.pakwingho.barpilot", category: "list-drag")
private let menuBarItemType = UTType(exportedAs: "local.pakwingho.barpilot.menu-item", conformingTo: .data)
private func menuBarItemProvider(_ id: String) -> NSItemProvider {
    let provider = NSItemProvider(object: id as NSString)
    provider.registerDataRepresentation(forTypeIdentifier: menuBarItemType.identifier, visibility: .all) {
        completion in
        completion(Data(id.utf8), nil)
        return nil
    }
    return provider
}
private struct BarPilotItemDropTarget: Equatable {
    let id: String
    let placement: MenuBarPlacement
}
private struct BarPilotListScope: Hashable {
    let query: String
    let visibility: MenuBarVisibility?
    let display: String?
    let group: UUID?
}
private struct BarPilotItemDropDelegate: DropDelegate {
    let id: String
    @Binding var draggingID: String?
    @Binding var target: BarPilotItemDropTarget?
    let canAccept: (String) -> Bool
    let perform: (String, MenuBarPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggingID else { return false }
        return info.hasItemsConforming(to: [menuBarItemType]) && canAccept(draggingID)
    }
    func dropEntered(info: DropInfo) { updateTarget(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        updateTarget(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if target?.id == id { target = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let source = draggingID else {
            menuBarDragLog.info("Rejected menu item drop")
            return false
        }
        let placement: MenuBarPlacement = info.location.y < 16 ? .before : .after
        draggingID = nil
        target = nil
        menuBarDragLog.info("Accepted menu item drop")
        perform(source, placement)
        return true
    }
    private func updateTarget(_ info: DropInfo) {
        guard validateDrop(info: info) else { return }
        target = BarPilotItemDropTarget(id: id, placement: info.location.y < 16 ? .before : .after)
    }
}
