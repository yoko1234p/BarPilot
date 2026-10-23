import Foundation
import CoreFoundation

public struct ProMediaSnapshot: Equatable {
    public let title: String
    public let artist: String
    public let bundleID: String?
    public let playing: Bool
    public let duration: Double?
    public let elapsed: Double?
    public let timestamp: Date?
    public let playbackRate: Double
    public let artwork: Data?
    public let shuffle: Int?
    public let repeatMode: Int?
    public func position(at date: Date) -> Double? {
        guard let elapsed else { return nil }
        let offset = playing ? max(0, date.timeIntervalSince(timestamp ?? date)) * playbackRate : 0
        return min(duration ?? .greatestFiniteMagnitude, max(0, elapsed + offset))
    }
    public static func parse(_ line: Data) -> ProMediaSnapshot? {
        guard line.count < 6 * 1024 * 1024,
            let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let object = envelope["payload"] as? [String: Any] ?? envelope
        guard let title = object["title"] as? String, !title.isEmpty else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        let encoded = object["artworkData"] as? String ?? object["artworkDataBase64"] as? String
        let artwork = encoded.flatMap { $0.count <= 5 * 1024 * 1024 ? Data(base64Encoded: $0) : nil }
        let duration = number("duration") ?? number("durationMicros").map { $0 / 1_000_000 }
        let elapsed = number("elapsedTime") ?? number("elapsedTimeMicros").map { $0 / 1_000_000 }
        let stamp = number("timestamp") ?? number("timestampEpochMicros").map { $0 / 1_000_000 }
        return ProMediaSnapshot(title: String(title.prefix(1000)), artist: String((object["artist"] as? String ?? "").prefix(1000)),
            bundleID: object["bundleIdentifier"] as? String, playing: object["playing"] as? Bool ?? object["isPlaying"] as? Bool ?? false,
            duration: duration.flatMap { (0...86400 * 30).contains($0) ? $0 : nil }, elapsed: elapsed.flatMap { (0...86400 * 30).contains($0) ? $0 : nil },
            timestamp: stamp.map { Date(timeIntervalSince1970: $0) }, playbackRate: max(0, min(8, number("playbackRate") ?? 1)),
            artwork: artwork, shuffle: number("shuffleMode").flatMap { (0...3).contains($0) ? Int($0) : nil },
            repeatMode: number("repeatMode").flatMap { (0...3).contains($0) ? Int($0) : nil })
    }
}
