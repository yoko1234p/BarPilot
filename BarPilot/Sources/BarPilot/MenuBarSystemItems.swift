import Darwin
import Foundation

/// Query all actual identifiers from the loaded macOS framework; never invent a numeric range.
enum MenuBarSystemItems {
    static let all: [NSNumber]? = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
            let framework = dlopen(
                "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
                RTLD_LAZY | RTLD_LOCAL),
            let metadata = dlsym(framework, "$s17MenuBarClientCore22MBSystemItemIdentifierOMa"),
            let cases = dlsym(framework, "$s17MenuBarClientCore22MBSystemItemIdentifierO8allCasesSayACGvgZ")
        else { return nil }
        // Swift's stable metadata response and Array return ABI; the element type is opened from actual metadata.
        let accessor = unsafeBitCast(metadata, to: (@convention(thin) (Int) -> (Any.Type, Int)).self)
        let (type, _) = accessor(0)
        func values<T>(_ type: T.Type) -> [Int]? {
            guard MemoryLayout<T>.size > 0, MemoryLayout<T>.size <= 32 else { return nil }
            let getter = unsafeBitCast(cases, to: (@convention(thin) () -> [T]).self)
            let actual = getter()
            guard !actual.isEmpty, actual.count < 64 else { return nil }
            let raw = actual.compactMap { ($0 as? any RawRepresentable)?.rawValue as? Int }
            guard raw.count == actual.count, Set(raw).count == raw.count,
                raw.allSatisfy({ $0 >= 0 && $0 < 4096 })
            else { return nil }
            return raw
        }
        return _openExistential(type, do: values)?.map { NSNumber(value: $0) }
    }()
}
