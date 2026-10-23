import BarPilotCore
import SwiftUI

struct DisplayLayoutsView: View {
    @ObservedObject var model: BarPilotModel
    @Environment(\.dismiss) private var dismiss
    @State private var presetID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("按螢幕套用布局")).font(.title2.bold())
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Toggle(
                L10n.text("螢幕組合改變後，自動套用已指定的布局"),
                isOn: Binding(
                    get: { model.settings.automaticDisplayLayouts == true }, set: model.setAutomaticDisplayLayouts))
            Text(L10n.text("目前：") + model.availableDisplays.map(\.name).joined(separator: " ＋ ")).font(.callout)
            HStack {
                Picker(L10n.text("目前組合使用"), selection: $presetID) {
                    Text(L10n.text("選擇布局")).tag(nil as UUID?)
                    ForEach(model.settings.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Button(L10n.text("記住組合")) { if let presetID { model.bindCurrentDisplays(to: presetID) } }.disabled(
                    presetID == nil)
            }
            if model.settings.presets.isEmpty { Text(L10n.text("先在主介面儲存布局，再指定螢幕組合。")).foregroundStyle(.secondary) }
            List(model.settings.displayLayoutRules ?? []) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.settings.presets.first(where: { $0.id == rule.presetID })?.name ?? L10n.text("布局"))
                            .fontWeight(.medium)
                        Text(
                            L10n.text("%1$@ 個螢幕", String(describing: rule.displayIDs.count))
                                + (rule.matches(model.availableDisplays.map(\.id))
                                    ? L10n.text(" · 目前組合") : L10n.text(" · 未接駁此組合"))
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("移除"), role: .destructive) { model.removeDisplayRule(rule.id) }
                }.padding(.vertical, 5)
            }
            if !model.displayLayoutStatus.isEmpty {
                Text(model.displayLayoutStatus).font(.caption).textSelection(.enabled)
            }
            Text(L10n.text("需要已啟用管理及排序權限。鎖屏、拖拉圖示、簡報模式或有待復原操作時會暫停；未有指定組合時保留現有布局。")).font(.caption).foregroundStyle(
                .secondary)
        }.padding(22).frame(width: 570, height: 440)
            .onAppear {
                presetID =
                    model.settings.displayLayoutRules?.first(where: { $0.matches(model.availableDisplays.map(\.id)) })?
                    .presetID ?? model.settings.presets.first?.id
            }
    }
}
