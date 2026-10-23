// UI mutations are restricted to BarPilot. Known peer status widgets are inspected read-only.
import AppKit
import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func nodes(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 18 else { return [] }
    var children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    if let menu = attribute(element, "AXShownMenuUIElement"), CFGetTypeID(menu) == AXUIElementGetTypeID() {
        children.append(menu as! AXUIElement)
    }
    return [element] + children.prefix(1000).flatMap { nodes($0, depth: depth + 1) }
}
func emit(_ value: Any) {
    func finiteJSON(_ value: Any) -> Any {
        if let object = value as? [String: Any] { return object.mapValues { finiteJSON($0) } }
        if let array = value as? [Any] { return array.map { finiteJSON($0) } }
        if let number = value as? NSNumber, !number.doubleValue.isFinite { return NSNull() }
        return value
    }
    let safeValue = finiteJSON(value)
    guard JSONSerialization.isValidJSONObject(safeValue),
        let data = try? JSONSerialization.data(withJSONObject: safeValue, options: [.sortedKeys])
    else { exit(4) }
    print(String(decoding: data, as: UTF8.self))
}
let args = CommandLine.arguments
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
guard (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true else {
    fputs("Desktop is locked.\n", stderr)
    exit(8)
}
guard args.count >= 3, let pid = Int32(args[2]),
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "local.pakwingho.barpilot",
    AXIsProcessTrusted()
else {
    fputs("Use ui-smoke dump|press|set|key <BarPilot-pid> [identifier/value].\n", stderr)
    exit(2)
}
let application = AXUIElementCreateApplication(pid)
let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
let all = windows.flatMap { nodes($0) }
switch args[1] {
case "activate":
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
case "close-window":
    guard let window = windows.first(where: { (attribute($0, kAXTitleAttribute) as? String) == "BarPilot" }),
        let close = attribute(window, kAXCloseButtonAttribute)
    else { exit(5) }
    let result = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
    emit(["result": result.rawValue])
    if result != .success { exit(6) }
case "recover-key":
    // The extra argument requires prior verification from the same process before closing its window.
    let verified = args.count == 4 && args[3] == "registered"
    let hint = all.first(where: { (attribute($0, kAXIdentifierAttribute) as? String) == "barpilot.recovery-hotkey" })
    guard verified || hint.flatMap({ attribute($0, kAXValueAttribute) as? String })?.contains("⌃⌥⇧B") == true
    else { exit(5) }
    let modifiers: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift)]
    guard CGPreflightPostEventAccess(),
        modifiers.allSatisfy({ !CGEventSource.keyState(.combinedSessionState, key: $0.0) })
    else { exit(7) }
    var flags: CGEventFlags = []
    for (key, flag) in modifiers {
        flags.insert(flag)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    for pressed in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: pressed)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    for (key, flag) in modifiers.reversed() {
        flags.remove(flag)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    emit(["postedRegisteredRecoveryHotkey": true])
case "status", "press-status", "click-status", "right-status":
    guard let extras = attribute(application, kAXExtrasMenuBarAttribute) else { exit(5) }
    let items = nodes(extras as! AXUIElement).filter {
        (attribute($0, kAXIdentifierAttribute) as? String) == "barpilot.status"
            || (attribute($0, kAXDescriptionAttribute) as? String)?.hasPrefix("BarPilot") == true
    }
    guard let item = items.first else { exit(5) }
    if args[1] == "press-status" {
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        emit(["result": result.rawValue])
        if result != .success { exit(6) }
    } else {
        var position = CGPoint.zero
        var size = CGSize.zero
        if let value = attribute(item, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        if let value = attribute(item, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(position.x + size.width / 2), Float(position.y + size.height / 2), &hit)
        var hitPID: pid_t = -1
        if let hit { AXUIElementGetPid(hit, &hitPID) }
        if args[1] == "status" {
            var localHit: AXUIElement?
            let localResult = AXUIElementCopyElementAtPosition(
                application, Float(position.x + size.width / 2), Float(position.y + size.height / 2), &localHit)
            emit([
                "identifier": attribute(item, kAXIdentifierAttribute) as? String ?? "",
                "description": attribute(item, kAXDescriptionAttribute) as? String ?? "",
                "x": position.x, "y": position.y, "width": size.width, "height": size.height,
                "hitResult": hitResult.rawValue, "hitIsBarPilot": hitPID == pid,
                "hitRole": hit.flatMap { attribute($0, kAXRoleAttribute) as? String } ?? "",
                "hitDescription": hit.flatMap { attribute($0, kAXDescriptionAttribute) as? String } ?? "",
                "hitIdentifier": hit.flatMap { attribute($0, kAXIdentifierAttribute) as? String } ?? "",
                "hitBundle": NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier ?? "system",
                "applicationHitResult": localResult.rawValue,
                "applicationHitIdentifier": localHit.flatMap { attribute($0, kAXIdentifierAttribute) as? String } ?? "",
            ])
        } else {
            let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
            guard size.width > 0, size.width <= 64, size.height > 0, size.height <= 64,
                hitResult == .success, hitPID == pid
            else {
                fputs("BarPilot status icon is covered or off-screen.\n", stderr)
                exit(9)
            }
            let right = args[1] == "right-status"
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            for type in right ? [CGEventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                CGEvent(
                    mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                    mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
                usleep(80_000)
            }
            emit(["clickedOwnStatus": true, "right": right])
        }
    }
case "pointer-screen", "status-screen", "click-status-screen":
    guard args.count == 4, ["builtin", "external"].contains(args[3]),
        let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return (CGDisplayIsBuiltin(number.uint32Value) != 0) == (args[3] == "builtin")
        })
    else { exit(5) }
    let top = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? 0
    let height = max(24, screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
    let y = top - screen.frame.maxY + height / 2
    if args[1] == "pointer-screen" {
        guard CGPreflightPostEventAccess() else { exit(7) }
        let point = CGPoint(x: screen.frame.midX, y: top - screen.frame.maxY + height + 100)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(80_000)
        emit(["screen": args[3], "movedPointerOnly": true, "x": point.x, "y": point.y])
        break
    }
    let system = AXUIElementCreateSystemWide()
    var point: CGPoint?
    for x in stride(from: screen.frame.maxX - 12, through: max(screen.frame.minX, screen.frame.maxX - 1000), by: -4) {
        var hit: AXUIElement?
        var owner: pid_t = -1
        guard AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit) == .success, let hit,
            AXUIElementGetPid(hit, &owner) == .success, owner == pid
        else { continue }
        if (attribute(hit, kAXIdentifierAttribute) as? String) == "barpilot.status" {
            point = CGPoint(x: x, y: y)
            break
        }
    }
    if point == nil, let extras = attribute(application, kAXExtrasMenuBarAttribute),
        let control = nodes(extras as! AXUIElement).first(where: {
            (attribute($0, kAXIdentifierAttribute) as? String) == "barpilot.status"
        }), let position = attribute(control, kAXPositionAttribute),
        let dimensions = attribute(control, kAXSizeAttribute),
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID()
    {
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
        if let source = NSScreen.screens.first(where: {
            $0.frame.minX <= origin.x && origin.x + size.width <= $0.frame.maxX
        }), size.width > 0, size.width <= 64 {
            let candidate = CGPoint(x: screen.frame.maxX - (source.frame.maxX - origin.x - size.width / 2), y: y)
            var hit: AXUIElement?
            var owner: pid_t = -1
            if candidate.x > screen.frame.midX,
                AXUIElementCopyElementAtPosition(system, Float(candidate.x), Float(candidate.y), &hit) == .success,
                let hit, AXUIElementGetPid(hit, &owner) == .success, owner == pid,
                (attribute(hit, kAXRoleAttribute) as? String) == kAXMenuBarRole
            {
                // The mirrored control belongs to BarPilot but macOS exposes only its bar root.
                point = candidate
            }
        }
    }
    guard let point else { exit(9) }
    if args[1] == "click-status-screen" {
        guard CGPreflightPostEventAccess(), !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            exit(7)
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(80_000)
        }
    }
    emit(["screen": args[3], "ownControlHit": true, "x": point.x, "y": point.y])
case "peer-windows":
    guard args.count == 4, ["com.lowtechguys.Clop", "com.pilotmoon.popclip-setapp"].contains(args[3]),
        let peer = NSRunningApplication.runningApplications(withBundleIdentifier: args[3]).first
    else { exit(5) }
    let info =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    emit(
        info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == peer.processIdentifier }.map {
            [
                "bounds": $0[kCGWindowBounds as String] ?? [:], "layer": $0[kCGWindowLayer as String] ?? 0,
                "id": $0[kCGWindowNumber as String] ?? 0,
            ]
        })
case "managed-items":
    // Read only known status widgets, never these apps' windows, notes, or capture results.
    let bundles = [
        "local.pakwingho.edgenotes", "com.lowtechguys.Clop", "local.pakwingho.capturetext",
        "com.apphousekitchen.aldente-pro-setapp", "com.pilotmoon.popclip-setapp", "com.wiheads.paste-setapp",
        "studio.fireball.OneSwitch-setapp", "com.apple.MenuBarAgent",
    ]
    emit(
        bundles.map { bundle -> [String: Any] in
            guard let peer = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
                return ["bundle": bundle, "running": false]
            }
            let ax = AXUIElementCreateApplication(peer.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.2)
            guard let extras = attribute(ax, kAXExtrasMenuBarAttribute), CFGetTypeID(extras) == AXUIElementGetTypeID()
            else {
                return ["bundle": bundle, "running": true, "items": []]
            }
            let items = nodes(extras as! AXUIElement).filter {
                let role = attribute($0, kAXRoleAttribute) as? String
                return role == kAXMenuBarItemRole || role == "AXMenuExtra"
            }.map { item -> [String: Any] in
                var point = CGPoint.zero
                var size = CGSize.zero
                if let value = attribute(item, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(value as! AXValue, .cgPoint, &point)
                }
                if let value = attribute(item, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                    AXValueGetValue(value as! AXValue, .cgSize, &size)
                }
                var hit: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(
                    AXUIElementCreateSystemWide(), Float(point.x + size.width / 2), Float(point.y + size.height / 2),
                    &hit)
                var owner: pid_t = -1
                if let hit { AXUIElementGetPid(hit, &owner) }
                return [
                    "identifier": attribute(item, kAXIdentifierAttribute) as? String ?? "",
                    "x": point.x, "y": point.y, "width": size.width, "height": size.height,
                    "hidden": (attribute(item, "AXHidden") as? NSNumber)?.boolValue ?? false,
                    "hitResult": result.rawValue, "hitIsOwner": owner == peer.processIdentifier,
                ]
            }
            return ["bundle": bundle, "running": true, "items": items]
        })
case "press-menu", "click-menu", "menu-probe":
    guard args[1] == "menu-probe" || args.count >= 4 else { exit(2) }
    let extras = attribute(application, kAXExtrasMenuBarAttribute)
    var menuNodes = all + nodes(application) + (extras.map { nodes($0 as! AXUIElement) } ?? [])
    if let focused = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
        CFGetTypeID(focused) == AXUIElementGetTypeID()
    {
        let element = focused as! AXUIElement
        var owner: pid_t = -1
        if AXUIElementGetPid(element, &owner) == .success, owner == pid { menuNodes += nodes(element) }
    }
    // Standalone native popup menus may be omitted from the application's window tree.
    // Hit-test only the popup immediately below our own control and accept this app's exact item.
    var probes: [[String: Any]] = []
    if let extras,
        let control = nodes(extras as! AXUIElement).first(where: {
            (attribute($0, kAXIdentifierAttribute) as? String) == "barpilot.status"
        }), let position = attribute(control, kAXPositionAttribute),
        let dimensions = attribute(control, kAXSizeAttribute),
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID()
    {
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
        let system = AXUIElementCreateSystemWide()
        for row in 0..<9 {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(
                system, Float(point.x + size.width / 2 + 25),
                Float(point.y + size.height + 18 + CGFloat(row) * 24), &hit) == .success, let hit
            {
                var owner: pid_t = -1
                AXUIElementGetPid(hit, &owner)
                let role = attribute(hit, kAXRoleAttribute) as? String ?? ""
                let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? "system"
                let knownHost = owner == pid || bundle == "com.apple.MenuBarAgent"
                let title =
                    knownHost && role == kAXMenuItemRole
                    ? (attribute(hit, kAXTitleAttribute) as? String ?? attribute(hit, kAXDescriptionAttribute)
                        as? String ?? "") : ""
                probes.append(["row": row, "owner": bundle, "role": role, "title": title])
                if owner == pid
                    || (bundle == "com.apple.MenuBarAgent"
                        && ["開啟 BarPilot…", "開啟 BarPilot...", "收起 BarPilot 視窗"].contains(title))
                {
                    menuNodes.append(hit)
                }
            }
        }
    }
    if args[1] == "menu-probe" {
        emit(probes)
        break
    }
    func menuTitle(_ value: String) -> String { value.replacingOccurrences(of: "…", with: "...") }
    guard
        let item = menuNodes.first(where: {
            (attribute($0, kAXTitleAttribute) as? String).map(menuTitle) == menuTitle(args[3])
        })
    else {
        exit(5)
    }
    if args[1] == "click-menu" {
        guard let position = attribute(item, kAXPositionAttribute), let dimensions = attribute(item, kAXSizeAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID(),
            CGPreflightPostEventAccess(), !CGEventSource.buttonState(.combinedSessionState, button: .left)
        else { exit(7) }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
        point = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
        var hit: AXUIElement?
        guard size.width > 0, size.width < 600, size.height > 0, size.height < 60,
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
                == .success,
            let hit
        else { exit(9) }
        var owner: pid_t = -1
        AXUIElementGetPid(hit, &owner)
        guard owner == pid, (attribute(hit, kAXTitleAttribute) as? String).map(menuTitle) == menuTitle(args[3]) else {
            exit(9)
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(
            tap: .cghidEventTap)
        usleep(120_000)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(
                tap: .cghidEventTap)
            usleep(80_000)
        }
        emit(["clickedOwnMenuItem": true])
        break
    }
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    emit(["result": result.rawValue])
    if result != .success { exit(6) }
case "window-info":
    let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    emit(
        info.filter {
            guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid,
                let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return rect.width > 200 && rect.height > 100
        }
        .map { ["id": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]] })
case "drag":
    guard (6...7).contains(args.count), args[3].hasPrefix("barpilot.drag."), args[4].hasPrefix("barpilot.item."),
        ["before", "after"].contains(args[5]),
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        CGPreflightPostEventAccess(), !CGEventSource.buttonState(.combinedSessionState, button: .left)
    else { exit(7) }
    func frame(_ id: String) -> CGRect? {
        guard let element = all.first(where: { (attribute($0, kAXIdentifierAttribute) as? String) == id }),
            let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
            CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
    guard let source = frame(args[3]), let target = frame(args[4]),
        source.width > 0, source.height > 0, target.height == 32
    else { exit(5) }
    let start = CGPoint(x: source.midX, y: source.midY)
    let end = CGPoint(x: target.minX + 110, y: target.minY + (args[5] == "before" ? 8 : 24))
    let system = AXUIElementCreateSystemWide()
    for (point, expectedID) in [(start, args[3]), (end, args[4])] {
        var hit: AXUIElement?
        var owner: pid_t = -1
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
            let hit, AXUIElementGetPid(hit, &owner) == .success, owner == pid
        else { exit(9) }
        var current: AXUIElement? = hit
        var path: [String] = []
        for _ in 0..<12 {
            guard let element = current else { break }
            if let id = attribute(element, kAXIdentifierAttribute) as? String { path.append(id) }
            current = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        guard path.contains(expectedID) else {
            emit(["expectedHit": expectedID, "actualPath": path])
            exit(9)
        }
    }
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?.post(
        tap: .cghidEventTap)
    usleep(100_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(
        tap: .cghidEventTap)
    usleep(150_000)
    for step in 1...24 {
        let fraction = CGFloat(step) / 24
        let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
            .post(
                tap: .cghidEventTap)
        usleep(35_000)
    }
    usleep(250_000)
    if args.count == 7, args[6].hasSuffix(".png"),
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
        let window = info.first(where: {
            guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid,
                let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return rect.width > 600 && rect.height > 300
        }), let number = window[kCGWindowNumber as String] as? NSNumber
    {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", number.stringValue, args[6]]
        try? capture.run()
        capture.waitUntilExit()
    }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(
        tap: .cghidEventTap)
    emit(["draggedOwnRow": true, "placement": args[5]])
case "dump":
    emit(
        all.prefix(5000).map { element -> [String: Any] in
            var record = [String: Any]()
            for name in [
                kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
            ] {
                if let text = attribute(element, name) as? String { record[name] = String(text.prefix(300)) }
            }
            if let enabled = attribute(element, kAXEnabledAttribute) as? NSNumber {
                record[kAXEnabledAttribute] = enabled.boolValue
            }
            var position = CGPoint.zero
            var size = CGSize.zero
            if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgPoint, &position)
                record["position"] = ["x": position.x, "y": position.y]
            }
            if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgSize, &size)
                record["size"] = ["width": size.width, "height": size.height]
            }
            return record
        })
case "press", "set", "click", "move":
    guard args.count >= 4,
        let target = all.first(where: {
            (attribute($0, kAXIdentifierAttribute) as? String) == args[3]
                || (attribute($0, kAXTitleAttribute) as? String) == args[3]
                || (attribute($0, kAXDescriptionAttribute) as? String) == args[3]
        })
    else { exit(5) }
    if args[1] == "click" || args[1] == "move" {
        guard args[3].hasPrefix("barpilot."), CGPreflightPostEventAccess(),
            !CGEventSource.buttonState(.combinedSessionState, button: .left),
            let position = attribute(target, kAXPositionAttribute),
            let dimensions = attribute(target, kAXSizeAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID()
        else { exit(7) }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
        let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard point.x.isFinite, point.y.isFinite, size.width > 0, size.height > 0 else { exit(5) }
        var hit: AXUIElement?
        var owner: pid_t = -1
        guard
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
                == .success, let hit, AXUIElementGetPid(hit, &owner) == .success, owner == pid
        else { exit(9) }
        var current: AXUIElement? = hit
        var matching = false
        for _ in 0..<12 {
            guard let element = current else { break }
            if (attribute(element, kAXIdentifierAttribute) as? String) == args[3] {
                matching = true
                break
            }
            current = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        guard matching else { exit(9) }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        if args[1] == "click" {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                usleep(80_000)
            }
        }
        emit(["ownElement": args[3], "action": args[1]])
        break
    }
    let result: AXError
    if args[1] == "set", args.count >= 5 {
        result = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, args[4] as CFString)
    } else {
        result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    }
    emit(["result": result.rawValue])
    if result != .success { exit(6) }
case "key":
    guard args.count >= 4, let key = UInt16(args[3]),
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
    else { exit(7) }
    down.flags = []
    up.flags = []
    down.postToPid(pid)
    up.postToPid(pid)
    usleep(200_000)
    emit(["postedToBarPilot": true, "postEventAccess": CGPreflightPostEventAccess()])
default: exit(2)
}
