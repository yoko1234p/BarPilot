import BarPilotCore
import Foundation
import XCTest

final class LaunchLocationTests: XCTestCase {
    func testExternalOrDevelopmentCopyCannotHideItsOwnControllerEvenWhenRegistered() {
        for path in ["/Volumes/ExternalFixture/Applications/BarPilot.app", "/tmp/BarPilotFixture/dist/BarPilot.app"] {
            let app = URL(fileURLWithPath: path)
            XCTAssertFalse(MenuBarLaunchLocation.supportsAssessment(running: app, registered: app))
        }
    }

    func testRegisteredSystemInstallationIsAcceptedAndStaleRegistrationIsRejected() {
        let installed = URL(fileURLWithPath: "/Applications/BarPilot.app")
        XCTAssertTrue(MenuBarLaunchLocation.supportsAssessment(running: installed, registered: installed))
        XCTAssertFalse(MenuBarLaunchLocation.supportsAssessment(running: installed, registered: nil))
        XCTAssertFalse(
            MenuBarLaunchLocation.supportsAssessment(
                running: installed, registered: URL(fileURLWithPath: "/Applications/BarPilot.previous.app")))
    }

    func testWorkShortcutResolvesToInstalledAppButSystemShortcutCannotMaskAnExternalBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let work = root.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let installed = applications.appendingPathComponent("BarPilot.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let shortcut = work.appendingPathComponent("BarPilot.app")
        try FileManager.default.createSymbolicLink(at: shortcut, withDestinationURL: installed)
        XCTAssertTrue(
            MenuBarLaunchLocation.supportsAssessment(
                running: installed, registered: shortcut, applicationsDirectory: applications))
        XCTAssertTrue(
            MenuBarLaunchLocation.supportsAssessment(
                running: shortcut, registered: installed, applicationsDirectory: applications))
        let external = work.appendingPathComponent("Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let misleading = applications.appendingPathComponent("Other.app")
        try FileManager.default.createSymbolicLink(at: misleading, withDestinationURL: external)
        XCTAssertFalse(
            MenuBarLaunchLocation.supportsAssessment(
                running: misleading, registered: misleading, applicationsDirectory: applications))
    }
}
