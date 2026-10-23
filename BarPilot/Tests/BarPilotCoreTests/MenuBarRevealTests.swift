import BarPilotCore
import Foundation
import XCTest

final class MenuBarRevealTests: XCTestCase {
    func testLongScreenSleepCancelsHoverAndRequiresLeavingControlAfterWake() {
        var state = MenuBarRevealState()
        state.managementEnabled = true
        state.pointerOverControl = true
        var timing = MenuBarRevealTiming()
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 0), .none)
        state.sessionActive = false
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 0.1), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3600), .none)
        state.sessionActive = true
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3601), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3610), .none)
        state.pointerOverControl = false
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3611), .none)
        state.pointerOverControl = true
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3612), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3612.3), .reveal)
    }

    func testSleepCancelsAutomaticHideDeadlineAsWell() {
        var state = MenuBarRevealState()
        state.managementEnabled = true
        state.expanded = true
        var timing = MenuBarRevealTiming()
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 0), .none)
        state.sessionActive = false
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3600), .none)
        state.sessionActive = true
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3601), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3602.6), .hide)
    }

    private func enabled() -> MenuBarRevealSettings {
        var settings = MenuBarRevealSettings()
        settings.hoverReveal = true
        settings.automaticallyHide = true
        return settings
    }
    func testHoverRequiresDelayAndEnabledManagement() {
        var state = MenuBarRevealState()
        state.pointerOverControl = true
        var timing = MenuBarRevealTiming()
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 0), .none)
        state.managementEnabled = true
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 1), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 1.2), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 1.3), .reveal)
    }
    func testHideCountdownStartsAfterLeavingEntireMenuBar() {
        var state = MenuBarRevealState()
        state.managementEnabled = true
        state.expanded = true
        var timing = MenuBarRevealTiming()
        state.pointerOverMenuBar = true
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 0), .none)
        state.pointerOverMenuBar = false
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 10), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 11), .none)
        XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 11.6), .hide)
    }
    func testLateMenuMouseDragPaletteEditorOrOperationCancelsPendingHide() {
        let mutations: [(inout MenuBarRevealState) -> Void] = [
            { $0.mouseDown = true }, { $0.menuTracking = true }, { $0.paletteVisible = true },
            { $0.editing = true }, { $0.working = true }, { $0.pointerOverMenuBar = true }, { $0.setupMode = true },
        ]
        for mutation in mutations {
            var state = MenuBarRevealState()
            state.managementEnabled = true
            state.expanded = true
            var timing = MenuBarRevealTiming()
            XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 0), .none)
            mutation(&state)
            XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 2), .none)
            state = MenuBarRevealState()
            state.managementEnabled = true
            state.expanded = true
            XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 3), .none)
            XCTAssertEqual(timing.step(state: state, settings: enabled(), now: 4.6), .hide)
        }
    }
    func testKeepOpenRechecksAtDeadlineAndManualCloseDoesNotImmediatelyHoverReopen() {
        var settings = enabled()
        var state = MenuBarRevealState()
        state.managementEnabled = true
        state.expanded = true
        var timing = MenuBarRevealTiming()
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 0), .none)
        settings.keepOpen = true
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 2), .none)
        timing.manuallyHidden()
        state.expanded = false
        state.pointerOverControl = true
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 3), .none)
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 5), .none)
        state.pointerOverControl = false
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 6), .none)
        state.pointerOverControl = true
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 7), .none)
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 7.3), .reveal)
    }
    func testPreviousSettingsDecodeAndNewTimersHaveBoundedDefaults() throws {
        let previous = Data(
            "{\"schemaVersion\":1,\"managementEnabled\":false,\"assignments\":[],\"groups\":[],\"presets\":[]}".utf8)
        let decoded = try JSONDecoder().decode(BarPilotSettings.self, from: previous)
        XCTAssertNil(decoded.reveal)
        XCTAssertFalse((decoded.reveal ?? MenuBarRevealSettings()).hoverReveal)
        var invalid = MenuBarRevealSettings()
        invalid.hideDelaySeconds = .infinity
        invalid.hoverDelaySeconds = -100
        XCTAssertEqual(invalid.sanitized.hideDelaySeconds, 1.5)
        XCTAssertEqual(invalid.sanitized.hoverDelaySeconds, 0.1)
    }
    func testOwnerOnlyRevealWaitsForItsMenuThenReconcealsWhileFullBarIsCollapsed() {
        var state = MenuBarRevealState()
        state.managementEnabled = true
        state.temporaryRevealActive = true
        state.expanded = false
        state.menuTracking = true
        var settings = MenuBarRevealSettings()
        settings.automaticallyHide = true
        var timing = MenuBarRevealTiming()
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 0), .none)
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 5), .none)
        state.menuTracking = false
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 6), .none)
        XCTAssertEqual(timing.step(state: state, settings: settings, now: 7.6), .hide)
    }
}
