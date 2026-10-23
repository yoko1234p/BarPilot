import AppKit

struct BarPilotDisplay: Identifiable, Sendable {
    let id: String
    let name: String
    let frame: CGRect
}

@MainActor enum MenuBarDisplays {
    static var current: [BarPilotDisplay] {
        let originHeight =
            NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.screens.first?.frame
            .maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let display = number.uint32Value
            let serial = CGDisplaySerialNumber(display)
            let identity =
                "\(CGDisplayVendorNumber(display)):\(CGDisplayModelNumber(display)):\(serial == 0 ? display : serial)"
            let frame = CGRect(
                x: screen.frame.minX, y: originHeight - screen.frame.maxY, width: screen.frame.width,
                height: screen.frame.height)
            return BarPilotDisplay(id: identity, name: screen.localizedName, frame: frame)
        }
    }
}
