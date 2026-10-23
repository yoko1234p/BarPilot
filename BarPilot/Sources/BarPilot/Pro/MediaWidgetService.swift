import AppKit
import BarPilotCore
import Combine
import CoreAudio
import ImageIO

enum ProPlayer: String, CaseIterable, Identifiable {
    case system = "系統播放", music = "Apple Music", spotify = "Spotify"
    var id: String { rawValue }
    var configurationKey: String { self == .system ? "system" : self == .music ? "music" : "spotify" }
    static func configured(_ key: String) -> ProPlayer { key == "music" ? .music : key == "spotify" ? .spotify : .system }
    var bundleID: String { self == .music ? "com.apple.Music" : self == .spotify ? "com.spotify.client" : "" }
}

@MainActor
final class MediaWidgetService: ObservableObject {
    @Published private(set) var enabled = false
    @Published var selectedPlayer = ProPlayer.system {
        didSet {
            onPlayerChanged?(selectedPlayer)
            guard enabled else { return }
            transport.stop(); snapshot = nil; artwork = nil; refresh()
        }
    }
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var playing = false
    @Published private(set) var status = "未啟用"
    @Published private(set) var volume: Double = 0
    @Published private(set) var volumeAvailable = false
    @Published private(set) var snapshot: ProMediaSnapshot?
    @Published private(set) var artwork: NSImage?
    private var timer: Timer?
    var onPlayerChanged: ((ProPlayer) -> Void)?
    private let transport = ProMediaTransport()
    init() {
        transport.onSnapshot = { [weak self] snapshot in
            guard let self, self.enabled, self.selectedPlayer == .system else { return }
            self.snapshot = snapshot; self.title = snapshot?.title ?? ""; self.artist = snapshot?.artist ?? ""
            self.playing = snapshot?.playing ?? false; self.artwork = self.decodeArtwork(snapshot?.artwork)
            self.status = snapshot.flatMap { value in value.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName } }
                ?? (snapshot == nil ? "系統沒有提供播放項目" : "系統播放")
        }
        transport.onFailure = { [weak self] message in
            guard let self, self.enabled, self.selectedPlayer == .system else { return }
            self.status = message
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value; timer?.invalidate(); timer = nil
        guard value else { transport.stop(); snapshot = nil; artwork = nil; title = ""; artist = ""; playing = false; status = "未啟用"; return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 1
    }
    func refresh() {
        guard enabled else { return }
        readVolume()
        if selectedPlayer == .system {
            if !transport.isRunning { status = "等待系統播放資料…"; transport.start() }
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: selectedPlayer.bundleID).contains(where: { !$0.isTerminated }) else {
            title = ""; artist = ""; playing = false
            status = "請先開啟 \(selectedPlayer.rawValue)。瀏覽器及其他播放器可嘗試「系統播放」。"; return
        }
        let target = selectedPlayer.bundleID
        let script = """
            tell application id "\(target)"
                if player state is stopped then return {"", "", "stopped"}
                return {name of current track, artist of current track, player state as string}
            end tell
            """
        guard let result = run(script) else { return }
        title = result.atIndex(1)?.stringValue ?? ""
        artist = result.atIndex(2)?.stringValue ?? ""
        playing = result.atIndex(3)?.stringValue == "playing"
        status = title.isEmpty ? "尚未播放音樂" : selectedPlayer.rawValue
    }
    func command(_ action: String) {
        guard enabled else { return }
        if selectedPlayer == .system {
            let commands = ["playpause": "2", "next track": "4", "previous track": "5", "shuffle": "6", "repeat": "7", "back15": "12", "forward15": "13"]
            if let command = commands[action] { transport.send(["send", command]) }
            return
        }
        guard ["playpause", "next track", "previous track"].contains(action),
            NSRunningApplication.runningApplications(withBundleIdentifier: selectedPlayer.bundleID).contains(where: { !$0.isTerminated }) else { return }
        _ = run("tell application id \"\(selectedPlayer.bundleID)\" to \(action)")
        refresh()
    }
    func seek(_ seconds: Double) {
        guard enabled, selectedPlayer == .system, seconds.isFinite, seconds >= 0, seconds <= 86400 * 30 else { return }
        transport.send(["seek", String(Int64((seconds * 1_000_000).rounded()))])
    }
    func setVolume(_ value: Double) {
        guard enabled, let device = defaultOutputDevice() else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var scalar = Float(max(0, min(1, value)))
        var writable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else {
            status = "呢個音效裝置不支援系統音量控制。"; return
        }
        if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &scalar) != noErr {
            status = "未能調整音量。"
        }
        readVolume()
    }
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            status = number == -1743 ? "需要在系統設定 → 隱私權與保安 → 自動化允許 \(selectedPlayer.rawValue)。"
                : "播放器未能回應：\(error[NSAppleScript.errorMessage] as? String ?? "未知錯誤")"
            return nil
        }
        return result
    }
    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr && device != 0 ? device : nil
    }
    private func readVolume() {
        guard let device = defaultOutputDevice() else { volumeAvailable = false; return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: Float = 0; var size = UInt32(MemoryLayout<Float>.size)
        volumeAvailable = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        if volumeAvailable { volume = Double(value) }
    }
    private func decodeArtwork(_ data: Data?) -> NSImage? {
        guard let data, data.count <= 4 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
