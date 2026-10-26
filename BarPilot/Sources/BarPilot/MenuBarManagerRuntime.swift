import AppKit
import ApplicationServices
import BarPilotCore
import BarPilotNative

/// Injectable system boundaries keep recovery tests away from the real menu bar and permissions.
@MainActor struct MenuBarManagerRuntime {
    var desktopInteractive: () -> Bool = { MenuBarDesktopSession.isInteractive }
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var usesAssessment = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    var verifiedLaunchLocation: () -> Bool = {
        MenuBarLaunchLocation.supportsAssessment(
            running: Bundle.main.bundleURL,
            registered: Bundle.main.bundleIdentifier.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            })
    }
    var competingManagers: () -> [String] = {
        NSWorkspace.shared.runningApplications.compactMap {
            let bundle = $0.bundleIdentifier?.lowercased() ?? ""
            let name = $0.localizedName ?? ""
            return bundle.contains("bartender") || name.lowercased().hasPrefix("bartender") ? name : nil
        }
    }
    var controlReachable: (() -> Bool)?
    var menuBarCanBeVerified: () -> Bool = { !MenuBarFullscreenPresentation.isActive() }
    var capabilityError: () -> String? = { BPAssessmentAssertion.capabilityError() }
    var systemItems: () -> [NSNumber]? = { MenuBarSystemItems.all }
    var runningBundles: () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    var activationTimeout: Duration = .seconds(5)
    var controlCheckDelays: [Duration] = [.milliseconds(350), .milliseconds(650), .seconds(1)]
    var fullscreenRecheckDelay: Duration = .seconds(2)
    var recoveryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30),
    ]
    var assessment = Assessment()

    struct Assessment {
        var activate: ([NSNumber], [String], @escaping @Sendable (Error?) -> Void) -> Void
        var invalidate: () -> Void

        init() {
            let assertion = BPAssessmentAssertion()
            activate = { systems, bundles, completion in
                assertion.activate(withSystemItems: systems, bundleIdentifiers: bundles, completion: completion)
            }
            invalidate = { assertion.invalidate() }
        }
    }
}
