import AppKit
import BarPilotCore
import XCTest

@testable import BarPilot

@MainActor final class MenuBarWakeRecoveryTests: XCTestCase {
    @MainActor private final class Fixture {
        enum Reply { case success, error, pending }
        var interactive = true
        var reachable = true
        var menuBarAvailable = true
        var trusted = true
        var reply = Reply.success
        var activations = 0
        var invalidations = 0
        var callbacks: [(Error?) -> Void] = []
        var settings: BarPilotSettings = {
            var settings = BarPilotSettings()
            settings.assign(.init(id: "hidden", visibility: .hidden))
            settings.assign(.init(id: "private", visibility: .alwaysHidden))
            return settings
        }()
        let items = ["hidden", "private"].map {
            MenuBarItem(
                id: $0, bundleIdentifier: "test.\($0)", applicationName: $0, title: $0, pid: 123,
                frame: nil, canActivate: true, hasStableIdentity: true)
        }
        lazy var manager: MenuBarManager = {
            var runtime = MenuBarManagerRuntime()
            runtime.usesAssessment = true
            runtime.desktopInteractive = { [weak self] in self?.interactive == true }
            runtime.controlReachable = { [weak self] in self?.reachable == true }
            runtime.menuBarCanBeVerified = { [weak self] in self?.menuBarAvailable == true }
            runtime.accessibilityTrusted = { [weak self] in self?.trusted == true }
            runtime.verifiedLaunchLocation = { true }
            runtime.competingManagers = { [] }
            runtime.capabilityError = { nil }
            runtime.systemItems = { [NSNumber(value: 0)] }
            runtime.runningBundles = { ["test.hidden", "test.private"] }
            runtime.activationTimeout = .milliseconds(40)
            runtime.controlCheckDelays = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]
            runtime.recoveryDelays = [.milliseconds(10)]
            runtime.assessment.activate = { [weak self] _, _, callback in
                guard let self else { return }
                activations += 1
                callbacks.append(callback)
                switch reply {
                case .success: callback(nil)
                case .error: callback(NSError(domain: "Test.MenuBarAgent", code: 1))
                case .pending: break
                }
            }
            runtime.assessment.invalidate = { [weak self] in self?.invalidations += 1 }
            return MenuBarManager(runtime: runtime)
        }()

        func start(expanded: Bool = false) async throws {
            try manager.enable()
            try await manager.applyNativePolicy(items: items, settings: settings, expanded: expanded)
        }

        func sleep() {
            interactive = false
            manager.suspendForSession()
        }

        func wake() {
            interactive = true
            manager.resumeAfterSession(items: items, settings: settings)
        }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Recovery condition was not reached", file: file, line: line)
    }

    func testCollapsedMenuSurvivesRepeatedActivationErrorsThenRecoversWithoutSetup() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.reply = .error
        fixture.wake()
        try await waitUntil { fixture.activations >= 4 }
        XCTAssertTrue(fixture.manager.isRecoveringSession)
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertFalse(fixture.manager.isSetupMode)
        fixture.reply = .success
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertNil(fixture.manager.issue)
        let completed = fixture.activations
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.activations, completed, "Successful recovery must stop polling")
    }

    func testActivationTimeoutAndLateCallbackCannotExpandCollapsedMenu() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.reply = .pending
        fixture.wake()
        try await waitUntil { fixture.activations >= 3 }
        let stale = fixture.callbacks[1]
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertFalse(fixture.manager.isSetupMode)
        fixture.reply = .success
        try await waitUntil { !fixture.manager.isRecoveringSession }
        stale(nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }

    func testUnavailableHostedControlDuringLongReflowKeepsPreviousIntent() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.reachable = false
        fixture.wake()
        try await waitUntil { fixture.activations >= 4 }
        XCTAssertTrue(fixture.manager.isRecoveringSession)
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertFalse(fixture.manager.isSetupMode)
        fixture.reachable = true
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }

    func testManualRevealCancelsWakeRetryAndRejectsItsLateCompletion() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.reply = .pending
        fixture.wake()
        try await waitUntil { fixture.activations == 2 }
        let stale = fixture.callbacks.last!
        fixture.reply = .success
        XCTAssertTrue(fixture.manager.showHidden())
        try await waitUntil { fixture.manager.hiddenExpanded && !fixture.manager.isApplying }
        stale(nil)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.manager.isRecoveringSession)
        XCTAssertTrue(fixture.manager.hiddenExpanded)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.private"])
        XCTAssertEqual(fixture.activations, 3)
    }

    func testAnotherSleepCancelsRecoveryAndDuplicateSuspensionsRetainCollapsedState() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.reply = .pending
        fixture.wake()
        try await waitUntil { fixture.activations == 2 }
        fixture.sleep()
        fixture.manager.suspendForSession()
        fixture.callbacks.last?(nil)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(fixture.activations, 2)
        XCTAssertFalse(fixture.manager.isRecoveringSession)
        fixture.reply = .success
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertFalse(fixture.manager.isSetupMode)
    }

    func testExpandedMenuIsRestoredExpandedAndSetupModeRemainsExplicit() async throws {
        let fixture = Fixture()
        try await fixture.start(expanded: true)
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertTrue(fixture.manager.hiddenExpanded)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.private"])
        fixture.manager.showAllForSetup()
        let before = fixture.activations
        fixture.sleep()
        fixture.wake()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.manager.isSetupMode)
        XCTAssertEqual(fixture.activations, before)
    }

    func testReorderInterruptedByLockRestoresPreOperationCollapsedState() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.manager.showAllForSetup()
        fixture.sleep()
        fixture.manager.restoreVisibilityAfterOperation(setup: false, expanded: false)
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertFalse(fixture.manager.isSetupMode)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }

    func testRevokedPermissionStopsRecoveryWithoutRepeatedRequests() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.trusted = false
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertNotNil(fixture.manager.issue)
        XCTAssertFalse(fixture.manager.isSetupMode)
    }

    func testLateControlReplacementAfterSuccessfulWakeRetriesWithoutEnteringSetup() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession }
        fixture.reachable = false
        let before = fixture.activations
        fixture.manager.verifyControlSoon()
        try await waitUntil { fixture.activations > before }
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertFalse(fixture.manager.isSetupMode)
        fixture.reachable = true
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }

    func testHiddenFullscreenMenuBarDoesNotTriggerControlRecovery() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.reachable = false
        fixture.menuBarAvailable = false
        let activations = fixture.activations
        let invalidations = fixture.invalidations
        fixture.manager.verifyControlSoon()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(fixture.activations, activations)
        XCTAssertEqual(fixture.invalidations, invalidations)
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
        fixture.menuBarAvailable = true
        fixture.manager.verifyControlSoon()
        try await waitUntil { fixture.activations > activations }
        fixture.reachable = true
        try await waitUntil { !fixture.manager.isRecoveringSession }
    }

    func testWakeIntoFullscreenKeepsRecoveredPolicyWithoutRepeatedReapplication() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        fixture.sleep()
        fixture.reachable = false
        fixture.menuBarAvailable = false
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession && fixture.activations >= 2 }
        let activations = fixture.activations
        let invalidations = fixture.invalidations
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(fixture.activations, activations)
        XCTAssertEqual(fixture.invalidations, invalidations)
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }

    func testTemporaryMenuRevealIsNotRestoredAsAFullExpansionAfterUnlock() async throws {
        let fixture = Fixture()
        try await fixture.start()
        defer { fixture.manager.disable() }
        try await fixture.manager.preserveActivation(bundle: "test.hidden", wasSetup: false, wasExpanded: false)
        XCTAssertTrue(fixture.manager.hasTemporaryReveal)
        fixture.sleep()
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertFalse(fixture.manager.hasTemporaryReveal)
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }

    func testLockDuringPendingCollapseRetainsAcceptedCollapsedIntent() async throws {
        let fixture = Fixture()
        try await fixture.start(expanded: true)
        defer { fixture.manager.disable() }
        fixture.reply = .pending
        XCTAssertTrue(fixture.manager.hideHidden())
        fixture.sleep()
        fixture.reply = .success
        fixture.wake()
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }

    func testPostWakeContextRefreshErrorRetriesWithoutErasingCollapsedIntent() async throws {
        let fixture = Fixture()
        try await fixture.start(expanded: true)
        defer { fixture.manager.disable() }
        fixture.reply = .error
        XCTAssertTrue(fixture.manager.hideHidden())
        try await waitUntil { fixture.activations >= 4 }
        XCTAssertFalse(fixture.manager.hiddenExpanded)
        XCTAssertFalse(fixture.manager.isSetupMode)
        fixture.reply = .success
        try await waitUntil { !fixture.manager.isRecoveringSession }
        XCTAssertEqual(fixture.manager.concealedBundles, ["test.hidden", "test.private"])
    }
}
