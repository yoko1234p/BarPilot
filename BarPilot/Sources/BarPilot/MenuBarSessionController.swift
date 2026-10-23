import AppKit
import BarPilotCore

@MainActor enum MenuBarDesktopSession {
    static var isInteractive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            session[kCGSessionOnConsoleKey as String] as? Bool == true,
            session["CGSSessionScreenIsLocked"] as? Bool != true
        else { return false }
        return NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsAsleep(number.uint32Value) == 0
        }
    }
}

@MainActor final class MenuBarSessionController {
    private let suspend: () -> Void
    private let resume: () async -> Void
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let desktopInteractive: @MainActor () -> Bool
    private let recoveryDelay: Duration
    private let retryDelay: Duration
    private var lifecycle = MenuBarSessionLifecycle()
    private var resumeTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        suspend: @escaping () -> Void, resume: @escaping () async -> Void,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        desktopInteractive: @escaping @MainActor () -> Bool = { MenuBarDesktopSession.isInteractive },
        recoveryDelay: Duration = .seconds(1), retryDelay: Duration = .milliseconds(500)
    ) {
        self.suspend = suspend
        self.resume = resume
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.desktopInteractive = desktopInteractive
        self.recoveryDelay = recoveryDelay
        self.retryDelay = retryDelay
    }

    func start() {
        let workspace = workspaceCenter
        for (sleep, wake, reason) in [
            (
                NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                MenuBarSessionLifecycle.InactiveReason.displays
            ),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .system),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .session),
        ] {
            observe(workspace, sleep) { [weak self] in self?.becameInactive(reason) }
            observe(workspace, wake) { [weak self] in self?.becameActive(reason) }
        }
        let distributed = distributedCenter
        observe(distributed, .init("com.apple.screenIsLocked")) { [weak self] in self?.becameInactive(.lock) }
        observe(distributed, .init("com.apple.screenIsUnlocked")) { [weak self] in self?.becameActive(.lock) }
        if !desktopInteractive() {
            // The next screen/session wake will request recovery even if startup missed the sleep.
            suspend()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, observer))
    }

    private func becameInactive(_ reason: MenuBarSessionLifecycle.InactiveReason) {
        lifecycle.suspend(reason)
        resumeTask?.cancel()
        resumeTask = nil
        suspend()
    }

    private func becameActive(_ reason: MenuBarSessionLifecycle.InactiveReason) {
        resumeTask?.cancel()
        // Keep automatic operations paused throughout MenuBarAgent's wake/reflow transition.
        suspend()
        _ = lifecycle.wake(reason)
        guard let request = lifecycle.pendingRecoveryRequest else { return }
        resumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: recoveryDelay) } catch { return }
            var readySamples = 0
            // A slow unlock can outlast a fixed retry window. This task stops on success,
            // another session event, or stop(); it does not poll during normal use.
            while !Task.isCancelled {
                let interactive = desktopInteractive()
                readySamples = interactive ? readySamples + 1 : 0
                if readySamples >= 2,
                    lifecycle.resume(request, desktopInteractive: interactive, reconcileInactiveReasons: true)
                {
                    await resume()
                    return
                }
                do { try await Task.sleep(for: retryDelay) } catch { return }
            }
        }
    }

    func stop() {
        resumeTask?.cancel()
        resumeTask = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
