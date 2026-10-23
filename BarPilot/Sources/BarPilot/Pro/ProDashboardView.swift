import AppKit
import BarPilotCore
import SwiftUI
import UniformTypeIdentifiers

struct ProDashboardView: View {
    @ObservedObject var services: BarPilotProServices
    let presets: [ProPresetChoice]
    @State private var selected = ProFeature.shelf
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("你的工作台").font(.title2.bold())
                    Text("按需要啟用。工作架只在你打開時顯示，可與 NotchHub 同時使用。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("開啟工作架", systemImage: "tray.2") { services.showShelf() }.disabled(!services.settings.shelf)
            }.padding(20)
            Divider()
            HSplitView {
                VStack(spacing: 4) {
                    ForEach(ProFeature.allCases) { feature in
                        Button { selected = feature } label: {
                            HStack {
                                Image(systemName: feature.symbol).frame(width: 24)
                                Text(feature.name)
                                Spacer()
                                if services.isEnabled(feature) { Circle().fill(.green).frame(width: 6, height: 6) }
                            }.padding(.horizontal, 10).padding(.vertical, 9)
                                .background(selected == feature ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(12).frame(minWidth: 200, maxWidth: 240)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Label(selected.name, systemImage: selected.symbol).font(.title3.bold())
                            Spacer()
                            Toggle("啟用", isOn: Binding(get: { services.isEnabled(selected) }, set: { services.enable(selected, $0) }))
                                .toggleStyle(.switch).fixedSize()
                        }
                        Text(selected.detail).font(.callout).foregroundStyle(.secondary)
                        if selected == .shelf, services.settings.shelf { ProCapsuleSettingsView(services: services) }
                        if selected == .clipboard, services.settings.clipboard { ProClipboardSettingsView(services: services) }
                        if selected == .automation {
                            ProAutomationEditor(service: services.automation, presets: presets)
                        } else {
                            ProFeatureContent(services: services, feature: selected)
                        }
                        if let notice = services.notice { Text(notice).foregroundStyle(.orange).textSelection(.enabled) }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 380)
            }
        }
    }
}

private struct ProClipboardSettingsView: View {
    @ObservedObject var services: BarPilotProServices
    var body: some View {
        HStack(spacing: 20) {
            Stepper("保存 \(services.settings.clipboardDays) 日", value: Binding(get: { services.settings.clipboardDays },
                set: { services.setClipboardPolicy(days: $0, limit: services.settings.clipboardLimit) }), in: 1...90)
            Stepper("最多 \(services.settings.clipboardLimit) 項", value: Binding(get: { services.settings.clipboardLimit },
                set: { services.setClipboardPolicy(days: services.settings.clipboardDays, limit: $0) }), in: 10...500, step: 10)
        }.font(.callout).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProCapsuleSettingsView: View {
    @ObservedObject var services: BarPilotProServices
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("顯示頂部膠囊／劉海工作架", isOn: Binding(get: { services.settings.capsule }, set: { services.enableCapsule($0) }))
                .toggleStyle(.switch)
            Picker("所在螢幕", selection: Binding(get: { services.settings.capsuleDisplay }, set: { services.enableCapsule(services.settings.capsule, display: $0) })) {
                Text("內置螢幕").tag("builtin")
                Text("外置螢幕").tag("external")
                ForEach(NSScreen.screens.map { ProScreenChoice(id: ProCapsuleController.identifier($0), name: $0.localizedName) }) { screen in
                    Text(screen.name).tag(screen.id)
                }
            }
            Text("滑鼠停留或點一下膠囊，從螢幕頂部中央向下及兩旁展開；離開後收起。釘選會保持展開，Esc 仍可收起。這個選項預設關閉，同一位置已有 NotchHub 時會保留原來面板。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProScreenChoice: Identifiable { let id: String; let name: String }

struct ProFeatureContent: View {
    @ObservedObject var services: BarPilotProServices
    let feature: ProFeature
    var body: some View {
        if services.isEnabled(feature) {
            switch feature {
            case .shelf: ProFileShelfView(service: services.files)
            case .clipboard: ProClipboardView(service: services.clipboard, close: services.closeShelf)
            case .calendar: ProCalendarView(service: services.calendar)
            case .media: ProMediaView(service: services.media)
            case .weather: ProWeatherView(services: services)
            case .system: ProSystemView(service: services.system)
            case .clocks: ProClocksView(services: services)
            case .agents: ProAgentsView(service: services.agents)
            case .automation: EmptyView()
            }
        } else {
            ContentUnavailableView("尚未啟用", systemImage: feature.symbol, description: Text("啟用「\(feature.name)」後即可使用。"))
        }
    }
}

private struct ProFileShelfView: View {
    @ObservedObject var service: FileShelfService
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(service.items.count) 個檔案參照").foregroundStyle(.secondary)
                Spacer()
                Button("加入檔案…", systemImage: "plus") { service.chooseFiles() }
            }
            VStack(spacing: 8) {
                if service.items.isEmpty {
                    Label("拖放檔案到這裡。原始檔案保持在原來位置。", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity, minHeight: 130).foregroundStyle(.secondary)
                }
                ForEach(service.items) { item in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: service.resolve(item)?.path ?? item.originalPath))
                            .resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).lineLimit(1)
                            Text(service.resolve(item) == nil ? "原始檔案不可用" : "拖出到其他 App 或 Finder")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { service.quickLook(item) } label: { Image(systemName: "eye") }.help("快速查看")
                        Menu {
                            Button("開啟") { service.open(item) }
                            Button("在 Finder 顯示") { service.reveal(item) }
                            Button("AirDrop…") { service.airDrop(item) }
                            Divider()
                            Button("移除參照", role: .destructive) { service.remove(item.id) }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 26)
                    }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .onDrag { service.resolve(item).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
                }
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(targeted ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(targeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(dash: [5])))
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                        guard let url = object as? URL else { return }
                        Task { @MainActor in service.add([url]) }
                    }
                }
                return !providers.isEmpty
            }
            if let message = service.message { Text(message).font(.callout).foregroundStyle(.orange) }
        }
    }
}

private struct ProClipboardView: View {
    @ObservedObject var service: ClipboardHistoryService
    let close: () -> Void
    @State private var search = ""
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜尋剪貼簿", text: $search).textFieldStyle(.roundedBorder)
                Button("清除", role: .destructive) { confirmClear = true }.disabled(service.entries.isEmpty)
            }
            if service.entries.isEmpty { Text("啟用後新複製的內容會出現在這裡。App 標記為敏感／暫時的內容不會保存。") .foregroundStyle(.secondary) }
            ForEach(service.entries.filter { search.isEmpty || $0.summary.localizedCaseInsensitiveContains(search) }) { entry in
                HStack(alignment: .top, spacing: 10) {
                    if entry.kind == .image, let image = NSImage(data: entry.data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 60, height: 50)
                    } else { Image(systemName: entry.kind == .files ? "doc" : "text.alignleft").frame(width: 28) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.summary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.copiedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { service.togglePin(entry.id) } label: { Image(systemName: entry.pinned ? "pin.fill" : "pin") }.help("釘選")
                    Menu {
                        Button("複製") { service.copy(entry) }
                        Button("貼上到上一個 App") { close(); service.copy(entry, paste: true) }
                        Button("刪除", role: .destructive) { service.delete(entry.id) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 26)
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let message = service.message { Text(message).font(.callout).foregroundStyle(.orange) }
        }.confirmationDialog("清除所有剪貼簿歷史，包括釘選項目？", isPresented: $confirmClear) {
            Button("清除本機歷史", role: .destructive) { service.clear() }
        }
    }
}

private struct ProCalendarView: View {
    @ObservedObject var service: CalendarWidgetService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(service.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("連接日曆") { service.connect() }
                Button("重新整理", systemImage: "arrow.clockwise") { service.refresh() }.labelStyle(.iconOnly)
            }
            ForEach(service.events) { event in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.headline)
                        HStack {
                            if event.allDay { Text("全天") } else { Text(event.start, style: .time); Text("–"); Text(event.end, style: .time) }
                            Text("· " + event.calendar)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if event.meetingURL != nil { Button("加入會議", systemImage: "video") { service.join(event) } }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Button("開啟日曆 App") { service.openCalendar() }
        }
    }
}

private struct ProMediaView: View {
    @ObservedObject var service: MediaWidgetService
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("播放器", selection: $service.selectedPlayer) {
                ForEach(ProPlayer.allCases) { player in Text(player.rawValue).tag(player) }
            }.pickerStyle(.segmented)
            HStack(spacing: 16) {
                if let artwork = service.artwork { Image(nsImage: artwork).resizable().scaledToFill().frame(width: 90, height: 90).clipShape(RoundedRectangle(cornerRadius: 12)) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(service.title.isEmpty ? service.status : service.title).font(.title3.bold())
                    if !service.artist.isEmpty { Text(service.artist).foregroundStyle(.secondary) }
                }
            }
            HStack(spacing: 24) {
                Button { service.command("previous track") } label: { Image(systemName: "backward.end.fill") }
                Button { service.command("playpause") } label: { Image(systemName: service.playing ? "pause.fill" : "play.fill") }
                Button { service.command("next track") } label: { Image(systemName: "forward.end.fill") }
                if service.selectedPlayer == .system {
                    Button { service.command("shuffle") } label: { Image(systemName: "shuffle") }.help("切換隨機播放")
                    Button { service.command("repeat") } label: { Image(systemName: "repeat") }.help("切換重複播放")
                }
                Spacer()
                Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }.buttonStyle(.bordered)
            if let snapshot = service.snapshot, let duration = snapshot.duration, duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(spacing: 5) {
                        Slider(value: Binding(get: { snapshot.position(at: timeline.date) ?? 0 }, set: service.seek), in: 0...duration)
                        HStack {
                            Text(Duration.seconds(snapshot.position(at: timeline.date) ?? 0).formatted(.time(pattern: .minuteSecond)))
                            Spacer()
                            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if service.volumeAvailable {
                HStack { Image(systemName: "speaker.fill"); Slider(value: Binding(get: { service.volume }, set: service.setVolume), in: 0...1); Image(systemName: "speaker.wave.3.fill") }
            }
            Text(service.status).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProWeatherView: View {
    @ObservedObject var services: BarPilotProServices
    @State private var city = "香港"
    @State private var latitude = "22.3193"
    @State private var longitude = "114.1694"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("城市", text: $city)
                TextField("緯度", text: $latitude)
                TextField("經度", text: $longitude)
                Button("設定") {
                    guard let lat = Double(latitude), let lon = Double(longitude) else { services.notice = "請輸入數字座標。"; return }
                    services.setWeatherLocation(WeatherLocation(name: city, latitude: lat, longitude: lon))
                }
            }.textFieldStyle(.roundedBorder)
            if let weather = services.weather.weather {
                HStack(spacing: 20) {
                    Image(systemName: weather.symbol).font(.system(size: 48)).symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading) {
                        Text("\(services.settings.weatherLocation?.name ?? "") · \(weather.current.temperature_2m, specifier: "%.0f")°C").font(.title.bold())
                        Text("體感 \(weather.current.apparent_temperature, specifier: "%.0f")° · 風速 \(weather.current.wind_speed_10m, specifier: "%.0f") km/h")
                        if let low = weather.daily.temperature_2m_min.first, let high = weather.daily.temperature_2m_max.first {
                            Text("\(low, specifier: "%.0f")°–\(high, specifier: "%.0f")° · 下雨機率 \(weather.daily.precipitation_probability_max.first ?? 0)%")
                        }
                    }
                }
            }
            HStack {
                Text(services.weather.status).font(.caption).foregroundStyle(.secondary)
                if let date = services.weather.updatedAt { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("更新") { services.weather.refresh() }
            }
            Link("Weather data by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
        }.onAppear {
            if let location = services.settings.weatherLocation { city = location.name; latitude = String(location.latitude); longitude = String(location.longitude) }
        }
    }
}

private struct ProSystemView: View {
    @ObservedObject var service: SystemWidgetService
    var body: some View {
        VStack(spacing: 12) {
            LabeledContent("電池") {
                if let percent = service.battery.percent {
                    Text("\(percent)% · \(service.battery.charging ? "充電中" : service.battery.pluggedIn ? "已插電" : "電池供電")")
                } else { Text("此 Mac 沒有可讀取的內置電池") }
            }
            if let disk = service.availableDiskGB { LabeledContent("可用磁碟") { Text("\(disk, specifier: "%.1f") GB") } }
            LabeledContent("實體記憶體") { Text("\(service.memoryGB, specifier: "%.0f") GB") }
            LabeledContent("已連接螢幕", value: "\(service.displayCount)")
            Button("重新整理") { service.refresh() }
        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProClocksView: View {
    @ObservedObject var services: BarPilotProServices
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ForEach(services.settings.timeZones, id: \.self) { id in
                    HStack {
                        Text(id.replacingOccurrences(of: "_", with: " "))
                        Spacer()
                        Text(context.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: TimeZone(identifier: id)!)))
                            .monospacedDigit()
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            TextField("每行一個時區，例如 Asia/Tokyo", text: $text, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            Button("儲存時區") { services.setTimeZones(text.components(separatedBy: .newlines)) }
        }.onAppear { text = services.settings.timeZones.joined(separator: "\n") }
    }
}

private struct ProAgentsView: View {
    @ObservedObject var service: AgentActivityService
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(service.agents) { agent in
                VStack(alignment: .leading, spacing: 8) {
                    Text(agent.name).font(.headline)
                    if let latest = agent.latestWrite {
                        HStack { Text("本機紀錄最近寫入"); Text(latest, style: .relative) }.font(.caption).foregroundStyle(.secondary)
                        Text("\(agent.localSessionFiles) 個已掃描紀錄；修改時間不代表 Agent 正在執行。") .font(.caption).foregroundStyle(.secondary)
                    } else { Text("未找到本機紀錄。").foregroundStyle(.secondary) }
                    if let quota = agent.quota, !quota.quotas.isEmpty {
                        if quota.isStale { Text("上次快照；資料已過時").foregroundStyle(.orange).font(.caption) }
                        ForEach(quota.quotas) { window in
                            HStack {
                                Text(window.id).font(.caption)
                                ProgressView(value: window.percent, total: 100).frame(maxWidth: 180)
                                Text("已用 \(window.percent, specifier: "%.0f")%").monospacedDigit()
                            }
                        }
                    } else { Text("用量未提供。可沿用 NotchHub 已建立的數字快照。").font(.caption).foregroundStyle(.secondary) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            Button(service.refreshing ? "重新整理中…" : "重新整理") { service.refresh() }.disabled(service.refreshing)
        }
    }
}
