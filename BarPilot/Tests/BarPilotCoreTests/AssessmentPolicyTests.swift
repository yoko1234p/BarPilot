import BarPilotCore
import XCTest

final class AssessmentPolicyTests: XCTestCase {
    private func item(_ id: String, _ bundle: String) -> MenuBarItem {
        MenuBarItem(
            id: id, bundleIdentifier: bundle, applicationName: bundle, title: id, pid: 123,
            frame: nil, canActivate: true, hasStableIdentity: true)
    }
    func testHiddenAndAlwaysHiddenHaveDifferentRevealBehavior() {
        var settings = BarPilotSettings()
        settings.assign(.init(id: "a", visibility: .hidden))
        settings.assign(.init(id: "b", visibility: .alwaysHidden))
        let items = [item("a", "app.a"), item("b", "app.b")]
        let closed = MenuBarAssessmentPolicy.make(
            items: items, settings: settings,
            runningBundles: ["app.a", "app.b", "unclassified"], ownBundle: "own", expanded: false)
        XCTAssertEqual(closed.concealedBundles, ["app.a", "app.b"])
        XCTAssertTrue(closed.allowedBundles.contains("unclassified"))
        XCTAssertTrue(closed.allowedBundles.contains("own"))
        let open = MenuBarAssessmentPolicy.make(
            items: items, settings: settings,
            runningBundles: ["app.a", "app.b"], ownBundle: "own", expanded: true)
        XCTAssertEqual(open.concealedBundles, ["app.b"])
    }
    func testOwnSystemAndUnresolvedOwnersAreNeverConcealed() {
        var settings = BarPilotSettings()
        let items = [item("own", "own"), item("clock", "com.apple.controlcenter"), item("gone", "gone")]
        for item in items { settings.assign(.init(id: item.id, visibility: .alwaysHidden)) }
        let policy = MenuBarAssessmentPolicy.make(
            items: items, settings: settings,
            runningBundles: ["own", "com.apple.controlcenter"], ownBundle: "own", expanded: false)
        XCTAssertTrue(policy.concealedBundles.isEmpty)
    }
    func testConflictingWidgetsOfOneOwnerRemainVisible() {
        var settings = BarPilotSettings()
        settings.assign(.init(id: "cpu", visibility: .hidden))
        settings.assign(.init(id: "memory", visibility: .visible))
        let policy = MenuBarAssessmentPolicy.make(
            items: [item("cpu", "stats"), item("memory", "stats")],
            settings: settings, runningBundles: ["stats"], ownBundle: "own", expanded: false)
        XCTAssertEqual(policy.mixedOwners, ["stats"])
        XCTAssertTrue(policy.concealedBundles.isEmpty)
        XCTAssertTrue(policy.allowedBundles.contains("stats"))
    }
    func testCanonicalBarPilotControlIsProtectedRegardlessOfHostOrSavedAssignment() {
        var settings = BarPilotSettings()
        settings.assign(.init(id: "control", visibility: .alwaysHidden))
        let policy = MenuBarAssessmentPolicy.make(
            items: [item("control", "local.pakwingho.barpilot")],
            settings: settings, runningBundles: ["local.pakwingho.barpilot"], ownBundle: "other.host", expanded: false)
        XCTAssertFalse(policy.concealedBundles.contains("local.pakwingho.barpilot"))
        XCTAssertTrue(policy.allowedBundles.contains("local.pakwingho.barpilot"))
    }
    func testRevealOrDisableRejectsOldActivationCallback() {
        var generation = MenuBarAssessmentGeneration()
        let request = generation.advance()
        XCTAssertTrue(generation.accepts(request))
        generation.advance()
        XCTAssertFalse(generation.accepts(request))
        XCTAssertTrue(generation.accepts(generation.value))
    }
    func testOverflowActivationKeepsOtherHiddenAndAlwaysHiddenOwnersConcealed() {
        var settings = BarPilotSettings()
        settings.assign(.init(id: "selected", visibility: .hidden))
        settings.assign(.init(id: "other", visibility: .hidden))
        settings.assign(.init(id: "private", visibility: .alwaysHidden))
        let items = [item("selected", "app.selected"), item("other", "app.other"), item("private", "app.private")]
        let policy = MenuBarAssessmentPolicy.make(
            items: items, settings: settings, runningBundles: ["app.selected", "app.other", "app.private"],
            ownBundle: "own", expanded: false, temporaryReveals: ["app.selected"])
        XCTAssertEqual(policy.concealedBundles, ["app.other", "app.private"])
        XCTAssertTrue(policy.allowedBundles.contains("app.selected"))
    }
    func testTemporaryActivationLeaseAllowsOnlySelectedAlwaysHiddenOwner() {
        var settings = BarPilotSettings()
        settings.assign(.init(id: "a", visibility: .alwaysHidden))
        settings.assign(.init(id: "b", visibility: .alwaysHidden))
        let items = [item("a", "app.a"), item("b", "app.b")]
        let open = MenuBarAssessmentPolicy.make(
            items: items, settings: settings,
            runningBundles: ["app.a", "app.b"], ownBundle: "own", expanded: true, temporaryReveals: ["app.a"])
        XCTAssertEqual(open.concealedBundles, ["app.b"])
        let restored = MenuBarAssessmentPolicy.make(
            items: items, settings: settings,
            runningBundles: ["app.a", "app.b"], ownBundle: "own", expanded: true)
        XCTAssertEqual(restored.concealedBundles, ["app.a", "app.b"])
    }
}
