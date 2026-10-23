import AppKit
import XCTest

@testable import BarPilot

@MainActor final class SessionControllerTests: XCTestCase {
    @MainActor private final class Fixture {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var interactive = true
        var suspensions = 0
        var resumptions = 0
        lazy var controller = MenuBarSessionController(
            suspend: { [weak self] in self?.suspensions += 1 },
            resume: { [weak self] in self?.resumptions += 1 },
            workspaceCenter: workspace, distributedCenter: distributed,
            desktopInteractive: { [weak self] in self?.interactive == true },
            recoveryDelay: .milliseconds(20), retryDelay: .milliseconds(20))
        func send(_ name: Notification.Name, distributed: Bool = false) {
            (distributed ? self.distributed : workspace).post(name: name, object: nil)
        }
    }

    private func waitForResume(_ fixture: Fixture) async throws {
        for _ in 0..<100 {
            if fixture.resumptions > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.resumptions, 1)
    }

    func testScreensWakeWhileLockedDoesNotRestoreOrExpandUntilUnlock() async throws {
        let fixture = Fixture()
        fixture.controller.start()
        defer { fixture.controller.stop() }
        fixture.interactive = false
        fixture.send(NSWorkspace.screensDidSleepNotification)
        fixture.send(.init("com.apple.screenIsLocked"), distributed: true)
        fixture.send(NSWorkspace.screensDidWakeNotification)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.resumptions, 0)
        fixture.interactive = true
        fixture.send(.init("com.apple.screenIsUnlocked"), distributed: true)
        try await waitForResume(fixture)
    }

    func testAnotherSleepCancelsQueuedRecoveryFromPreviousWake() async throws {
        let fixture = Fixture()
        fixture.controller.start()
        defer { fixture.controller.stop() }
        fixture.send(NSWorkspace.screensDidSleepNotification)
        fixture.send(NSWorkspace.screensDidWakeNotification)
        fixture.send(NSWorkspace.screensDidSleepNotification)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.resumptions, 0)
        fixture.send(NSWorkspace.screensDidWakeNotification)
        try await waitForResume(fixture)
    }

    func testWakeWaitsForActualDesktopReadinessThenResumesOnlyOnce() async throws {
        let fixture = Fixture()
        fixture.controller.start()
        defer { fixture.controller.stop() }
        fixture.interactive = false
        fixture.send(NSWorkspace.screensDidSleepNotification)
        fixture.send(NSWorkspace.screensDidWakeNotification)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.resumptions, 0)
        fixture.interactive = true
        try await waitForResume(fixture)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.resumptions, 1)
    }

    func testStopCancelsRecoveryAndUnregistersBothNotificationCenters() async throws {
        let fixture = Fixture()
        fixture.controller.start()
        fixture.send(NSWorkspace.screensDidSleepNotification)
        fixture.send(NSWorkspace.screensDidWakeNotification)
        fixture.controller.stop()
        let before = fixture.suspensions
        fixture.send(NSWorkspace.willSleepNotification)
        fixture.send(.init("com.apple.screenIsLocked"), distributed: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.suspensions, before)
        XCTAssertEqual(fixture.resumptions, 0)
    }

    func testSlowLoginBeyondPreviousRetryWindowStillRestoresWithoutAnotherNotification() async throws {
        let fixture = Fixture()
        fixture.controller.start()
        defer { fixture.controller.stop() }
        fixture.interactive = false
        fixture.send(NSWorkspace.screensDidSleepNotification)
        fixture.send(NSWorkspace.screensDidWakeNotification)
        // Ten former retries plus the initial delay would have stopped by now.
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(fixture.resumptions, 0)
        fixture.interactive = true
        try await waitForResume(fixture)
    }

    func testUnlockRecoversWithConfirmedDesktopEvenIfOneWakeNotificationIsMissing() async throws {
        let fixture = Fixture()
        fixture.controller.start()
        defer { fixture.controller.stop() }
        fixture.interactive = false
        fixture.send(NSWorkspace.screensDidSleepNotification)
        fixture.send(.init("com.apple.screenIsLocked"), distributed: true)
        fixture.send(.init("com.apple.screenIsUnlocked"), distributed: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.resumptions, 0)
        fixture.interactive = true
        try await waitForResume(fixture)
    }
}
