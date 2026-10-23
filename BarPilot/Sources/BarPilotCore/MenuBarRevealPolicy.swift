import Foundation

public struct MenuBarRevealSettings: Codable, Equatable, Sendable {
    public var hoverReveal = false
    public var automaticallyHide = false
    public var keepOpen = false
    public var hoverDelaySeconds = 0.25
    public var hideDelaySeconds = 1.5
    public init() {}
    public var sanitized: MenuBarRevealSettings {
        var value = self
        value.hoverDelaySeconds = hoverDelaySeconds.isFinite ? min(1, max(0.1, hoverDelaySeconds)) : 0.25
        value.hideDelaySeconds = hideDelaySeconds.isFinite ? min(15, max(0.3, hideDelaySeconds)) : 1.5
        return value
    }
}

public struct MenuBarRevealState: Sendable {
    public var sessionActive = true
    public var managementEnabled = false
    public var expanded = false
    public var temporaryRevealActive = false
    public var setupMode = false
    public var pointerOverControl = false
    public var pointerOverMenuBar = false
    public var mouseDown = false
    public var menuTracking = false
    public var paletteVisible = false
    public var editing = false
    public var working = false
    public init() {}
}

public struct MenuBarRevealTiming: Sendable {
    public enum Action: Equatable, Sendable { case none, reveal, hide }
    private var hoverDeadline: Double?
    private var hideDeadline: Double?
    private var hoverSuppressed = false
    public init() {}
    public mutating func manuallyHidden() {
        hoverSuppressed = true
        hoverDeadline = nil
        hideDeadline = nil
    }
    public mutating func reset() {
        hoverDeadline = nil
        hideDeadline = nil
    }
    public mutating func step(state: MenuBarRevealState, settings: MenuBarRevealSettings, now: Double) -> Action {
        guard state.sessionActive else {
            manuallyHidden()
            return .none
        }
        let settings = settings.sanitized
        let expanded = state.expanded || state.temporaryRevealActive
        if !state.pointerOverControl { hoverSuppressed = false }
        guard state.managementEnabled, !state.setupMode, !state.working else {
            reset()
            return .none
        }
        let interacting = state.mouseDown || state.menuTracking || state.paletteVisible || state.editing
        if settings.hoverReveal, !expanded, state.pointerOverControl, !hoverSuppressed, !interacting {
            hideDeadline = nil
            if hoverDeadline == nil { hoverDeadline = now + settings.hoverDelaySeconds }
            if now >= hoverDeadline! {
                hoverDeadline = nil
                return .reveal
            }
        } else {
            hoverDeadline = nil
        }
        if settings.automaticallyHide, expanded, !settings.keepOpen, !state.pointerOverMenuBar, !interacting {
            if hideDeadline == nil { hideDeadline = now + settings.hideDelaySeconds }
            if now >= hideDeadline! {
                hideDeadline = nil
                return .hide
            }
        } else {
            hideDeadline = nil
        }
        return .none
    }
}
