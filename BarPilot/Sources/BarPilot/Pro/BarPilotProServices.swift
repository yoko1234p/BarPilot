import AppKit
import BarPilotCore
import Combine
import SwiftUI

enum ProFeature: String, CaseIterable, Identifiable {
    case shelf, clipboard, calendar, media, weather, system, clocks, agents, automation
    var id: String { rawValue }
    var name: String {
        switch self {
        case .shelf: return "工作架"
        case .clipboard: return "剪貼簿歷史"
        case .calendar: return "日曆"
        case .media: return "音樂及音量"
        case .weather: return "天氣"
        case .system: return "電池及系統"
        case .clocks: return "世界時鐘"
        case .agents: return "Codex / Claude Code"
        case .automation: return "自動化及動作"
        }
    }
    var symbol: String {
        switch self {
        case .shelf: return "tray.2"
        case .clipboard: return "doc.on.clipboard"
        case .calendar: return "calendar"
        case .media: return "music.note"
        case .weather: return "cloud.sun"
        case .system: return "battery.100percent"
        case .clocks: return "clock"
        case .agents: return "terminal"
        case .automation: return "bolt"
        }
    }
    var detail: String {
        switch self {
        case .shelf: return "獨立、按需開啟的工作架；拖放檔案參照，預覽及傳送。"
        case .clipboard: return "啟用後才收集新複製的文字、圖片及檔案。可設定保存日數及項數，總量最多 20 MB；略過 App 標記為敏感／暫時的內容。"
        case .calendar: return "你授權後讀取未來 24 小時行程，直接加入已附有連結的會議。"
        case .media: return "讀取並控制 macOS 提供的系統播放，包括支援的瀏覽器及音樂 App。Music／Spotify 可選直接控制；macOS 可能要求自動化權限。"
        case .weather: return "只把你設定的城市座標傳送到 Open-Meteo；不讀定位、不發天氣提醒。"
        case .system: return "顯示實際電池、可用磁碟、實體記憶體及顯示器數目。"
        case .clocks: return "在工作架查看各地時間；時區可更改。"
        case .agents: return "只查看本機檔案修改時間和 NotchHub 已有的數字用量快照；不讀提示詞、對話或登入憑證。"
        case .automation: return "依前景 App、螢幕、電池或時間套用預設；只執行你明確新增的捷徑或本機腳本。"
        }
    }
}

struct ProPresetChoice: Identifiable { let id: UUID; let name: String }

@MainActor
final class BarPilotProServices: ObservableObject {
    @Published private(set) var settings: ProFeatureSettings
    @Published var notice: String?
    let files: FileShelfService
    let clipboard: ClipboardHistoryService
    let calendar = CalendarWidgetService()
    let media = MediaWidgetService()
    let weather = WeatherWidgetService()
    let system = SystemWidgetService()
    let agents: AgentActivityService
    private(set) var automation: ProAutomationService!
    var bringMainWindow: (() -> Void)?
    private let file: URL
    private var shelfController: ProShelfPanelController?
    private var capsuleController: ProCapsuleController?
    private var observation: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    init(directory: URL, applyPreset: @escaping (UUID) -> Void, bringMainWindow: (() -> Void)? = nil) {
        file = directory.appendingPathComponent("workspace-settings.json")
        settings = (try? ProStorage.read(ProFeatureSettings.self, at: file, maxBytes: 128 * 1024)) ?? ProFeatureSettings()
        files = FileShelfService(directory: directory); clipboard = ClipboardHistoryService(directory: directory)
        agents = AgentActivityService(); self.bringMainWindow = bringMainWindow
        automation = ProAutomationService(directory: directory, applyPreset: applyPreset, showShelf: { [weak self] in self?.showShelf() })
        media.onPlayerChanged = { [weak self] player in
            guard let self, self.settings.mediaSource != player.configurationKey else { return }
            self.settings.mediaSource = player.configurationKey; self.save()
        }
        for publisher in [files.objectWillChange, clipboard.objectWillChange, calendar.objectWillChange,
            media.objectWillChange, weather.objectWillChange, system.objectWillChange, agents.objectWillChange, automation.objectWillChange] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        // Restores only options the user has previously enabled. Every first-run option is false.
        reconcile()
    }
    func isEnabled(_ feature: ProFeature) -> Bool {
        switch feature {
        case .shelf: return settings.shelf
        case .clipboard: return settings.clipboard
        case .calendar: return settings.calendar
        case .media: return settings.media
        case .weather: return settings.weather
        case .system: return settings.system
        case .clocks: return settings.clocks
        case .agents: return settings.agents
        case .automation: return settings.automation
        }
    }
    func enable(_ feature: ProFeature, _ enabled: Bool) {
        switch feature {
        case .shelf:
            settings.shelf = enabled; files.setEnabled(enabled)
            if !enabled { shelfController?.close(); capsuleController?.stop(); settings.capsule = false }
        case .clipboard: settings.clipboard = enabled; clipboard.setEnabled(enabled)
        case .calendar: settings.calendar = enabled; calendar.setEnabled(enabled, requestPermission: enabled)
        case .media: settings.media = enabled; media.setEnabled(enabled)
        case .weather: settings.weather = enabled; weather.setEnabled(enabled)
        case .system: settings.system = enabled; system.setEnabled(enabled)
        case .clocks: settings.clocks = enabled
        case .agents: settings.agents = enabled; agents.setEnabled(enabled)
        case .automation: settings.automation = enabled; automation.setEnabled(enabled)
        }
        updateAppObservation(); save()
    }
    func setWeatherLocation(_ location: WeatherLocation) {
        guard location.isValid else { notice = "緯度須為 −90 至 90，經度須為 −180 至 180。"; return }
        settings.weatherLocation = location; weather.location = location; save()
    }
    func setTimeZones(_ values: [String]) {
        var seen = Set<String>()
        let valid = values.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { TimeZone(identifier: $0) != nil && seen.insert($0).inserted }
        guard !valid.isEmpty, valid.count <= 8 else { notice = "請輸入 1–8 個有效時區，例如 Asia/Hong_Kong。"; return }
        settings.timeZones = valid; save()
    }
    func setClipboardPolicy(days: Int, limit: Int) {
        settings.clipboardDays = max(1, min(days, 90)); settings.clipboardLimit = max(1, min(limit, 500))
        clipboard.updatePolicy(days: settings.clipboardDays, limit: settings.clipboardLimit); save()
    }
    func showShelf() {
        guard settings.shelf else { notice = "請先在工作台啟用工作架。"; bringMainWindow?(); return }
        if settings.capsule, let capsuleController, capsuleController.isVisible { capsuleController.expand(); return }
        if shelfController == nil { shelfController = ProShelfPanelController(services: self) }
        shelfController?.show()
    }
    func enableCapsule(_ value: Bool, display: String? = nil) {
        if let display { settings.capsuleDisplay = display }
        guard value, settings.shelf else { capsuleController?.stop(); settings.capsule = false; save(); return }
        shelfController?.close()
        if capsuleController == nil { capsuleController = ProCapsuleController(services: self) }
        settings.capsule = capsuleController?.start(display: settings.capsuleDisplay) == true
        if !settings.capsule { capsuleController?.stop() }
        save()
    }
    func closeShelf() { shelfController?.close(); capsuleController?.collapse(force: true) }
    func stop() {
        shelfController?.close()
        capsuleController?.stop()
        files.setEnabled(false); clipboard.setEnabled(false); calendar.setEnabled(false)
        media.setEnabled(false); weather.setEnabled(false); system.setEnabled(false)
        agents.setEnabled(false); automation.setEnabled(false)
        if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation); self.observation = nil }
    }
    private func reconcile() {
        clipboard.days = settings.clipboardDays; clipboard.limit = settings.clipboardLimit
        media.selectedPlayer = ProPlayer.configured(settings.mediaSource)
        weather.location = settings.weatherLocation
        files.setEnabled(settings.shelf); clipboard.setEnabled(settings.clipboard)
        calendar.setEnabled(settings.calendar); media.setEnabled(settings.media)
        weather.setEnabled(settings.weather); system.setEnabled(settings.system)
        agents.setEnabled(settings.agents); automation.setEnabled(settings.automation)
        if settings.capsule && settings.shelf { enableCapsule(true) }
        updateAppObservation()
    }
    private func updateAppObservation() {
        if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation); self.observation = nil }
        guard settings.clipboard else { clipboard.previousApplication = nil; return }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            clipboard.previousApplication = app
        }
        observation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.clipboard.previousApplication = app }
        }
    }
    private func save() { do { try ProStorage.write(settings, to: file) } catch { notice = error.localizedDescription } }
}
