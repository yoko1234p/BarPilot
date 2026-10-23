import Foundation

public enum BarPilotHotKeyCommand: UInt32, Sendable {
    case search = 1
    case recover = 2
    public static let signature: UInt32 = 0x4250_4C54
    public static func decode(signature: UInt32, id: UInt32) -> Self? {
        guard signature == Self.signature else { return nil }
        return Self(rawValue: id)
    }
}
