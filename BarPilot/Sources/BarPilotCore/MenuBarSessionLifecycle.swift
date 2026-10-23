import Foundation

/// Screen wake and session unlock arrive independently. Neither alone permits recovery.
public struct MenuBarSessionLifecycle: Sendable {
    public enum InactiveReason: Hashable, Sendable { case displays, system, lock, session }
    private var reasons: Set<InactiveReason> = []
    private var recoveryPending = false
    private var generation: UInt64 = 0
    public var isSuspended: Bool { recoveryPending || !reasons.isEmpty }
    public var pendingRecoveryRequest: UInt64? { recoveryPending ? generation : nil }
    public init() {}

    public mutating func suspend(_ reason: InactiveReason) {
        reasons.insert(reason)
        recoveryPending = true
        generation &+= 1
    }

    /// A wake without a matching sleep still invalidates any cached native assertion.
    public mutating func wake(_ reason: InactiveReason) -> UInt64? {
        reasons.remove(reason)
        recoveryPending = true
        generation &+= 1
        return reasons.isEmpty ? generation : nil
    }

    public mutating func resume(
        _ request: UInt64, desktopInteractive: Bool, reconcileInactiveReasons: Bool = false
    ) -> Bool {
        guard recoveryPending, request == generation, desktopInteractive,
            reasons.isEmpty || reconcileInactiveReasons
        else { return false }
        // Notifications are hints. A confirmed unlocked, awake console can reconcile a missing wake.
        reasons.removeAll()
        recoveryPending = false
        return true
    }
}
