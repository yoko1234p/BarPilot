import AppKit
import ApplicationServices

/// The menu bar's visibility belongs to the calling app, so BarPilot must inspect
/// the on-screen presentation instead of asking NSMenu about its own menu bar.
@MainActor enum MenuBarFullscreenPresentation {
    static func isActive() -> Bool {
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(number.uint32Value)
        }
        guard !displays.isEmpty else { return false }

        // An on-screen video can fill a display without creating a new Space. A
        // notched display may leave a small top inset, so inspect that window's
        // AX full-screen flag even when a different app is active on another mon.
        var candidateOwners = Set<pid_t>()
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            for window in windows {
                guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                    owner != getpid(),
                    (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                    (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                    let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                    let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { continue }
                if displays.contains(where: { coversDisplay(frame, display: $0) }) { return true }
                if displays.contains(where: { nearlyCoversDisplay(frame, display: $0) }) {
                    candidateOwners.insert(owner)
                }
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != getpid() {
            candidateOwners.insert(frontmost.processIdentifier)
        }
        return candidateOwners.contains(where: axWindowIsFullscreen)
    }

    private static func axWindowIsFullscreen(pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
            axFullscreen(focused as! AXUIElement) { return true }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success,
            let list = windows as? [AXUIElement]
        else { return false }
        return list.prefix(12).contains(where: axFullscreen)
    }

    private static func axFullscreen(_ window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.15)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success
            && (value as? NSNumber)?.boolValue == true
    }

    static func coversDisplay(_ window: CGRect, display: CGRect) -> Bool {
        let tolerance: CGFloat = 4
        return window.width > 0 && window.height > 0
            && abs(window.minX - display.minX) <= tolerance
            && abs(window.minY - display.minY) <= tolerance
            && abs(window.maxX - display.maxX) <= tolerance
            && abs(window.maxY - display.maxY) <= tolerance
    }

    static func nearlyCoversDisplay(_ window: CGRect, display: CGRect) -> Bool {
        let topInset = window.minY - display.minY
        return window.width > 0 && window.height >= display.height * 0.85
            && abs(window.minX - display.minX) <= 4
            && abs(window.maxX - display.maxX) <= 4
            && topInset >= -4 && topInset <= 64
            && abs(window.maxY - display.maxY) <= 4
    }
}
