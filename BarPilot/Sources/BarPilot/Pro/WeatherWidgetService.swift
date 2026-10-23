import BarPilotCore
import Combine
import Foundation

struct ProWeather: Decodable {
    struct Current: Decodable {
        let time: String
        let temperature_2m: Double
        let apparent_temperature: Double
        let weather_code: Int
        let is_day: Int
        let wind_speed_10m: Double
    }
    struct Daily: Decodable {
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int]
    }
    let current: Current
    let daily: Daily
    var symbol: String {
        switch current.weather_code {
        case 0: return current.is_day == 1 ? "sun.max.fill" : "moon.stars.fill"
        case 1...3: return "cloud.sun.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

@MainActor
final class WeatherWidgetService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var weather: ProWeather?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var status = "未啟用"
    var location: WeatherLocation? { didSet { if location != oldValue { refresh() } } }
    private var task: Task<Void, Never>?
    private var timer: Timer?
    func setEnabled(_ value: Bool) {
        enabled = value; timer?.invalidate(); timer = nil; task?.cancel(); task = nil
        guard value else { weather = nil; updatedAt = nil; status = "未啟用"; return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 60
    }
    func refresh() {
        guard enabled else { return }
        task?.cancel()
        guard let url = location?.requestURL else { weather = nil; status = "請設定城市座標。"; return }
        status = "更新中…"
        task = Task { @MainActor in
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard enabled else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 512 * 1024 else {
                    throw ProServiceError.message("天氣服務暫時未能回應。")
                }
                weather = try JSONDecoder().decode(ProWeather.self, from: data)
                updatedAt = Date(); status = "Open-Meteo"
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                status = weather == nil ? error.localizedDescription : "顯示上次資料；" + error.localizedDescription
            }
        }
    }
}
