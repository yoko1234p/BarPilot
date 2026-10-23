import AppKit
import BarPilotCore
import SwiftUI
import UniformTypeIdentifiers

struct ProAutomationEditor: View {
    @ObservedObject var service: ProAutomationService
    let presets: [ProPresetChoice]
    @State private var newRule = false
    @State private var newWidget = false
    @State private var editingRule: ProAutomationRule?
    @State private var editingWidget: ProActionWidget?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("條件規則").font(.headline)
                Spacer()
                Button("新增規則", systemImage: "plus") { newRule = true }
            }
            if service.rules.isEmpty { Text("新增規則後再個別啟用；不會自動加入或執行任何腳本。").foregroundStyle(.secondary) }
            ForEach(service.rules) { rule in
                HStack(spacing: 12) {
                    Toggle("啟用規則", isOn: Binding(get: { service.rules.first { $0.id == rule.id }?.enabled ?? false }, set: { value in
                        guard let index = service.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                        service.rules[index].enabled = value
                    })).toggleStyle(.switch).labelsHidden()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.name).font(.headline)
                        Text(rule.conditions.map(\.label).joined(separator: " ＋ ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(rule.action.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("編輯") { editingRule = rule }
                    Button("測試動作") { service.run(rule.action) }.disabled(!service.enabled || service.running)
                    Button { service.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.help("刪除規則")
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            HStack {
                Text("工作架動作按鈕").font(.headline)
                Spacer()
                Button("新增按鈕", systemImage: "plus") { newWidget = true }
            }
            ForEach(service.widgets) { widget in
                HStack {
                    Label(widget.name, systemImage: widget.symbol)
                    Text(widget.action.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("編輯") { editingWidget = widget }
                    Button("執行") { service.run(widget.action) }.disabled(!service.enabled || service.running)
                    Button { service.widgets.removeAll { $0.id == widget.id } } label: { Image(systemName: "trash") }.help("刪除按鈕")
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Text(service.status).font(.callout).foregroundStyle(.secondary)
            Text("同一規則只有條件由不符合變為符合時才會執行，至少相隔 5 分鐘。捷徑及腳本不會取得剪貼簿或日曆內容。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $newRule) {
            ProRuleComposer(presets: presets) { service.rules.append($0); newRule = false }
        }
        .sheet(isPresented: $newWidget) {
            ProWidgetComposer(presets: presets) { service.widgets.append($0); newWidget = false }
        }
        .sheet(item: $editingRule) { original in
            ProRuleComposer(presets: presets, initialRule: original) { updated in
                if let index = service.rules.firstIndex(where: { $0.id == original.id }) { service.rules[index] = updated }
                editingRule = nil
            }
        }
        .sheet(item: $editingWidget) { original in
            ProWidgetComposer(presets: presets, initialWidget: original) { updated in
                if let index = service.widgets.firstIndex(where: { $0.id == original.id }) { service.widgets[index] = updated }
                editingWidget = nil
            }
        }
    }
}

private enum ProActionKind: String, CaseIterable, Identifiable {
    case preset = "套用預設", shelf = "開啟工作架", shortcut = "執行捷徑", script = "執行本機腳本"
    var id: String { rawValue }
}

private struct ProActionDraft {
    var kind = ProActionKind.shelf
    var preset: UUID?
    var shortcut = ""
    var script = ""
    var arguments = ""
    init() {}
    init(action: ProAction) {
        switch action {
        case .showShelf: kind = .shelf
        case .preset(let id): kind = .preset; preset = id
        case .shortcut(let name): kind = .shortcut; shortcut = name
        case .localScript(let path, let args): kind = .script; script = path; arguments = args.joined(separator: "\n")
        }
    }
    var value: ProAction? {
        switch kind {
        case .shelf: return .showShelf
        case .preset: return preset.map(ProAction.preset)
        case .shortcut:
            let name = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || name.count > 200 ? nil : .shortcut(name: name)
        case .script:
            guard script.hasPrefix("/"), ["sh", "zsh", "py", "js"].contains(URL(fileURLWithPath: script).pathExtension.lowercased()) else { return nil }
            let args = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard args.count <= 50, args.allSatisfy({ $0.count <= 4096 }) else { return nil }
            return .localScript(path: script, arguments: args)
        }
    }
}

private struct ProActionFields: View {
    @Binding var draft: ProActionDraft
    let presets: [ProPresetChoice]
    var body: some View {
        Picker("動作", selection: $draft.kind) { ForEach(ProActionKind.allCases) { Text($0.rawValue).tag($0) } }
        switch draft.kind {
        case .shelf: Text("按需開啟 BarPilot 工作架；需先啟用工作架。").font(.caption).foregroundStyle(.secondary)
        case .preset:
            Picker("預設", selection: $draft.preset) {
                Text("選擇預設").tag(Optional<UUID>.none)
                ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
            }
        case .shortcut:
            TextField("捷徑 App 裏現有捷徑的完整名稱", text: $draft.shortcut)
        case .script:
            HStack {
                Text(draft.script.isEmpty ? "選取你信任的本機腳本" : URL(fileURLWithPath: draft.script).lastPathComponent)
                    .lineLimit(1).textSelection(.enabled)
                Spacer()
                Button("選取…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    panel.allowedContentTypes = [.shellScript, .pythonScript, .javaScript]
                    if panel.runModal() == .OK, let url = panel.url { draft.script = url.path }
                }
            }
            TextField("可選引數：每行一個，毋須 Shell 引號", text: $draft.arguments, axis: .vertical).lineLimit(2...5)
            Text("只執行這個檔案；名稱及引數不會拼接成 Shell 指令。執行限時 60 秒。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProRuleComposer: View {
    let presets: [ProPresetChoice]
    let save: (ProAutomationRule) -> Void
    let initialRule: ProAutomationRule?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var useApp = false
    @State private var appID = ""
    @State private var useDisplays = false
    @State private var minDisplays = 2
    @State private var maxDisplays = 3
    @State private var useBattery = false
    @State private var percent = 20
    @State private var batteryOnly = true
    @State private var useSchedule = false
    @State private var start = 10 * 60 + 30
    @State private var end = 19 * 60 + 30
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var draft = ProActionDraft()
    init(presets: [ProPresetChoice], initialRule: ProAutomationRule? = nil, save: @escaping (ProAutomationRule) -> Void) {
        self.presets = presets; self.initialRule = initialRule; self.save = save
        guard let initialRule else { return }
        _name = State(initialValue: initialRule.name); _draft = State(initialValue: ProActionDraft(action: initialRule.action))
        for condition in initialRule.conditions {
            switch condition {
            case .frontApplication(let id): _useApp = State(initialValue: true); _appID = State(initialValue: id)
            case .displayCount(let low, let high):
                _useDisplays = State(initialValue: true); _minDisplays = State(initialValue: low); _maxDisplays = State(initialValue: high)
            case .batteryBelow(let threshold, let batteryOnly):
                _useBattery = State(initialValue: true); _percent = State(initialValue: threshold); _batteryOnly = State(initialValue: batteryOnly)
            case .schedule(let start, let end, let weekdays):
                _useSchedule = State(initialValue: true); _start = State(initialValue: start); _end = State(initialValue: end); _weekdays = State(initialValue: Set(weekdays))
            }
        }
    }
    private var conditionsValid: Bool {
        (!useApp || !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!useDisplays || maxDisplays >= minDisplays)
            && (!useSchedule || (start != end && !weekdays.isEmpty))
    }
    private var conditions: [AutomationCondition] {
        var result: [AutomationCondition] = []
        if useApp, !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.frontApplication(bundleID: appID.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if useDisplays, maxDisplays >= minDisplays { result.append(.displayCount(minimum: minDisplays, maximum: maxDisplays)) }
        if useBattery { result.append(.batteryBelow(percent: percent, onBatteryOnly: batteryOnly)) }
        if useSchedule, start != end, !weekdays.isEmpty { result.append(.schedule(startMinute: start, endMinute: end, weekdays: weekdays.sorted())) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(initialRule == nil ? "新增自動化規則" : "編輯自動化規則").font(.title2.bold())
            Form {
                TextField("規則名稱", text: $name)
                Text("所選條件須全部符合。新規則保持停用；修改規則會保留原來的開關。") .font(.caption).foregroundStyle(.secondary)
                Toggle("前景 App", isOn: $useApp)
                if useApp {
                    HStack {
                        TextField("Bundle ID，例如 com.apple.Safari", text: $appID)
                        Button("選取 App…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
                            if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { appID = id }
                        }
                    }
                }
                Toggle("已連接顯示器數目", isOn: $useDisplays)
                if useDisplays {
                    Stepper("至少 \(minDisplays) 個", value: $minDisplays, in: 1...8)
                    Stepper("最多 \(maxDisplays) 個", value: $maxDisplays, in: 1...8)
                }
                Toggle("電池低於門檻", isOn: $useBattery)
                if useBattery {
                    Stepper("低於 \(percent)%", value: $percent, in: 1...100)
                    Toggle("只在使用電池時", isOn: $batteryOnly)
                }
                Toggle("指定時段", isOn: $useSchedule)
                if useSchedule {
                    HStack {
                        ProMinutePicker(title: "開始", minute: $start)
                        ProMinutePicker(title: "結束", minute: $end)
                    }
                    HStack {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(["日", "一", "二", "三", "四", "五", "六"][day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
                                .toggleStyle(.button)
                        }
                    }
                }
                Divider()
                ProActionFields(draft: $draft, presets: presets)
            }.formStyle(.grouped)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(initialRule == nil ? "儲存停用規則" : "儲存修改") {
                    if let action = draft.value {
                        var rule = ProAutomationRule(name: name, conditions: conditions, action: action)
                        if let initialRule { rule.id = initialRule.id; rule.enabled = initialRule.enabled; rule.cooldown = initialRule.cooldown }
                        save(rule)
                    }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !conditionsValid || conditions.isEmpty || draft.value == nil)
            }
        }.padding(20).frame(width: 560, height: 650)
    }
}

private struct ProMinutePicker: View {
    let title: String
    @Binding var minute: Int
    var body: some View {
        HStack {
            Text(title)
            Picker("時", selection: Binding(get: { minute / 60 }, set: { minute = $0 * 60 + minute % 60 })) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.labelsHidden()
            Picker("分", selection: Binding(get: { minute % 60 }, set: { minute = minute / 60 * 60 + $0 })) {
                ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.labelsHidden()
        }
    }
}

private struct ProWidgetComposer: View {
    let presets: [ProPresetChoice]
    let save: (ProActionWidget) -> Void
    let initialWidget: ProActionWidget?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var draft = ProActionDraft()
    init(presets: [ProPresetChoice], initialWidget: ProActionWidget? = nil, save: @escaping (ProActionWidget) -> Void) {
        self.presets = presets; self.initialWidget = initialWidget; self.save = save
        if let initialWidget { _name = State(initialValue: initialWidget.name); _draft = State(initialValue: ProActionDraft(action: initialWidget.action)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(initialWidget == nil ? "新增工作架動作" : "編輯工作架動作").font(.title2.bold())
            Form {
                TextField("按鈕名稱", text: $name)
                ProActionFields(draft: $draft, presets: presets)
            }.formStyle(.grouped)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("儲存") {
                    if let action = draft.value {
                        var widget = ProActionWidget(name: name, action: action)
                        if let initialWidget { widget.id = initialWidget.id; widget.symbol = initialWidget.symbol }
                        save(widget)
                    }
                }
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || draft.value == nil)
            }
        }.padding(20).frame(width: 540, height: 380)
    }
}
