import AppKit
import Combine
import IOKit.ps

struct ProBatteryState: Equatable {
    var percent: Int?
    var pluggedIn = true
    var charging = false
}

enum ProSystemReader {
    static func battery() -> ProBatteryState {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(information)?.takeRetainedValue() as? [CFTypeRef] else { return ProBatteryState() }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(information, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let capacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            guard maximum > 0 else { continue }
            return ProBatteryState(percent: min(100, max(0, capacity * 100 / maximum)),
                pluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return ProBatteryState()
    }
}

@MainActor
final class SystemWidgetService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var battery = ProBatteryState()
    @Published private(set) var availableDiskGB: Double?
    @Published private(set) var memoryGB: Double = 0
    @Published private(set) var displayCount = 0
    private var timer: Timer?
    func setEnabled(_ value: Bool) {
        enabled = value; timer?.invalidate(); timer = nil
        guard value else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 5
    }
    func refresh() {
        guard enabled else { return }
        battery = ProSystemReader.battery(); displayCount = NSScreen.screens.count
        memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / pow(1024, 3)
        let volume = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableDiskGB = volume?.volumeAvailableCapacityForImportantUsage.map { Double($0) / pow(1024, 3) }
    }
}
