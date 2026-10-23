import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = destination.appendingPathComponent("BarPilot.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = CGFloat(pixels) * 0.06
        let shape = NSBezierPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: CGFloat(pixels) * 0.23,
            yRadius: CGFloat(pixels) * 0.23)
        NSGradient(
            starting: NSColor(red: 0.12, green: 0.32, blue: 0.69, alpha: 1),
            ending: NSColor(red: 0.12, green: 0.75, blue: 0.70, alpha: 1))!.draw(in: shape, angle: -60)
        let bar = NSRect(
            x: CGFloat(pixels) * 0.20, y: CGFloat(pixels) * 0.43, width: CGFloat(pixels) * 0.60,
            height: CGFloat(pixels) * 0.20)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bar, xRadius: CGFloat(pixels) * 0.055, yRadius: CGFloat(pixels) * 0.055).fill()
        NSColor(red: 0.15, green: 0.40, blue: 0.65, alpha: 1).setFill()
        for x in [0.32, 0.50, 0.68] {
            NSBezierPath(
                ovalIn: NSRect(
                    x: CGFloat(pixels) * (x - 0.04), y: CGFloat(pixels) * 0.49, width: CGFloat(pixels) * 0.08,
                    height: CGFloat(pixels) * 0.08)
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", destination.appendingPathComponent("BarPilot.icns").path, iconset.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: iconset)
