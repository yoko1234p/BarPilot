import Foundation

public struct ProCapsuleGeometry: Equatable {
    public var screenFrame: CGRect
    public var topInset: CGFloat
    public var notchWidth: CGFloat
    public init(screenFrame: CGRect, topInset: CGFloat, notchWidth: CGFloat) {
        self.screenFrame = screenFrame
        self.topInset = max(24, topInset)
        self.notchWidth = max(120, notchWidth)
    }
    public var collapsedSize: CGSize { CGSize(width: min(screenFrame.width - 24, notchWidth + 100), height: topInset + 5) }
    public var expandedSize: CGSize { CGSize(width: min(780, screenFrame.width - 24), height: min(550, screenFrame.height - 60)) }
    public func frame(expanded: Bool) -> CGRect {
        let size = expanded ? expandedSize : collapsedSize
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}

public struct ProCapsuleInteraction: Equatable {
    public var pinned = false
    public var pointerInside = false
    public var mouseDown = false
    public var dropTargeted = false
    public var hasOverlay = false
    public init() {}
    public var canAutoCollapse: Bool { !pinned && !pointerInside && !mouseDown && !dropTargeted && !hasOverlay }
}
