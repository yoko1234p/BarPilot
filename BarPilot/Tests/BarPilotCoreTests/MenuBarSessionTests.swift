import BarPilotCore
import XCTest

final class MenuBarSessionTests: XCTestCase {
    func testScreenWakeDoesNotResumeBeforeUnlock() throws {
        var lifecycle = MenuBarSessionLifecycle()
        lifecycle.suspend(.displays)
        lifecycle.suspend(.lock)
        XCTAssertNil(lifecycle.wake(.displays))
        XCTAssertTrue(lifecycle.isSuspended)
        let request = try XCTUnwrap(lifecycle.wake(.lock))
        XCTAssertTrue(lifecycle.resume(request, desktopInteractive: true))
        XCTAssertFalse(lifecycle.isSuspended)
    }

    func testUnlockDoesNotResumeWhileComputerOrDisplaysAreStillAsleep() throws {
        var lifecycle = MenuBarSessionLifecycle()
        for reason in [MenuBarSessionLifecycle.InactiveReason.displays, .system, .lock, .session] {
            lifecycle.suspend(reason)
        }
        XCTAssertNil(lifecycle.wake(.lock))
        XCTAssertNil(lifecycle.wake(.system))
        XCTAssertNil(lifecycle.wake(.session))
        let request = try XCTUnwrap(lifecycle.wake(.displays))
        XCTAssertFalse(lifecycle.resume(request, desktopInteractive: false))
        XCTAssertTrue(lifecycle.isSuspended)
        XCTAssertTrue(lifecycle.resume(request, desktopInteractive: true))
    }

    func testReLockRejectsTheAlreadyQueuedWakeRecovery() throws {
        var lifecycle = MenuBarSessionLifecycle()
        lifecycle.suspend(.lock)
        let stale = try XCTUnwrap(lifecycle.wake(.lock))
        lifecycle.suspend(.lock)
        XCTAssertFalse(lifecycle.resume(stale, desktopInteractive: true))
        let current = try XCTUnwrap(lifecycle.wake(.lock))
        XCTAssertTrue(lifecycle.resume(current, desktopInteractive: true))
        XCTAssertFalse(lifecycle.resume(current, desktopInteractive: true))
    }

    func testDuplicateSleepNeedsOnlyOneMatchingWake() throws {
        var lifecycle = MenuBarSessionLifecycle()
        lifecycle.suspend(.displays)
        lifecycle.suspend(.displays)
        let request = try XCTUnwrap(lifecycle.wake(.displays))
        XCTAssertTrue(lifecycle.resume(request, desktopInteractive: true))
    }

    func testWakeStillRefreshesPolicyIfStartupMissedSleepNotification() throws {
        var lifecycle = MenuBarSessionLifecycle()
        XCTAssertFalse(lifecycle.isSuspended)
        let request = try XCTUnwrap(lifecycle.wake(.displays))
        XCTAssertTrue(lifecycle.isSuspended)
        XCTAssertTrue(lifecycle.resume(request, desktopInteractive: true))
    }

    func testOverlappingWakeNotificationsPermitOnlyLatestRecovery() throws {
        var lifecycle = MenuBarSessionLifecycle()
        lifecycle.suspend(.displays)
        let first = try XCTUnwrap(lifecycle.wake(.displays))
        let latest = try XCTUnwrap(lifecycle.wake(.system))
        XCTAssertFalse(lifecycle.resume(first, desktopInteractive: true))
        XCTAssertTrue(lifecycle.resume(latest, desktopInteractive: true))
    }

    func testConfirmedDesktopCanReconcileMissingWakeWithoutAcceptingLockedOrStaleRequest() throws {
        var lifecycle = MenuBarSessionLifecycle()
        lifecycle.suspend(.displays)
        lifecycle.suspend(.lock)
        XCTAssertNil(lifecycle.wake(.lock))
        let stale = try XCTUnwrap(lifecycle.pendingRecoveryRequest)
        XCTAssertFalse(lifecycle.resume(stale, desktopInteractive: false, reconcileInactiveReasons: true))
        lifecycle.suspend(.lock)
        XCTAssertFalse(lifecycle.resume(stale, desktopInteractive: true, reconcileInactiveReasons: true))
        _ = lifecycle.wake(.lock)
        let current = try XCTUnwrap(lifecycle.pendingRecoveryRequest)
        XCTAssertTrue(lifecycle.resume(current, desktopInteractive: true, reconcileInactiveReasons: true))
        XCTAssertFalse(lifecycle.isSuspended)
        XCTAssertNil(lifecycle.pendingRecoveryRequest)
    }
}
