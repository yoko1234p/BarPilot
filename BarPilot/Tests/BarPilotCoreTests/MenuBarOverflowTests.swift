import BarPilotCore
import CoreGraphics
import Foundation
import XCTest

final class MenuBarOverflowTests: XCTestCase {
    private func item(_ id: String, width: Double = 28, bundle: String = "test.app") -> MenuBarItem {
        MenuBarItem(
            id: id, bundleIdentifier: bundle, applicationName: id, title: id, pid: 1,
            frame: CGRect(x: 0, y: 0, width: width, height: 24), canActivate: true, hasStableIdentity: true)
    }
    func testNotchAndSoftwareOverlayReduceAvailableWidth() {
        let items = (0..<14).map { item("\($0)") }
        let right = CGRect(x: 950, y: 0, width: 760, height: 34)
        XCTAssertFalse(
            MenuBarOverflow.requiresPanel(mode: .automatic, items: items, rightMenuArea: right, occlusions: []))
        XCTAssertTrue(
            MenuBarOverflow.requiresPanel(
                mode: .automatic, items: items, rightMenuArea: right,
                occlusions: [CGRect(x: 700, y: 0, width: 540, height: 67)]))
        XCTAssertTrue(MenuBarOverflow.requiresPanel(mode: .always, items: [], rightMenuArea: right, occlusions: []))
    }
    func testInvalidWidthsUseBoundedEstimatesAndRightEdgeOcclusionCannotProduceNegativeSpace() {
        let right = CGRect(x: 0, y: 0, width: 400, height: 30)
        XCTAssertFalse(
            MenuBarOverflow.requiresPanel(
                mode: .automatic, items: [item("invalid", width: .infinity)], rightMenuArea: right, occlusions: []))
        XCTAssertTrue(
            MenuBarOverflow.requiresPanel(
                mode: .automatic, items: [item("app")], rightMenuArea: right,
                occlusions: [CGRect(x: 390, y: 0, width: 200, height: 30)]))
    }
    func testExistingOverlapTriggersPanelEvenWhenTotalWidthsWouldFit() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 30)
        XCTAssertTrue(
            MenuBarOverflow.requiresPanel(
                mode: .automatic, items: [item("app")], rightMenuArea: area,
                occlusions: [CGRect(x: 0, y: 0, width: 40, height: 67)]))
    }
    func testConcealedInventorySurvivesScopedActivationWithoutKeepingExitedAppsOrDuplicates() {
        let fresh = item("selected", bundle: "app.selected")
        let concealed = item("concealed", bundle: "app.hidden")
        let visibleMissing = item("gone", bundle: "app.visible")
        let result = MenuBarOverflow.mergingVisibleInventory(
            [fresh], remembered: [fresh, concealed, concealed, visibleMissing],
            concealedOwners: ["app.selected", "app.hidden"], runningPIDs: [1])
        XCTAssertEqual(result.map(\.id), ["selected", "concealed"])
        XCTAssertEqual(
            MenuBarOverflow.mergingVisibleInventory(
                [], remembered: [concealed], concealedOwners: ["app.hidden"], runningPIDs: []
            ).count, 0)
    }
    func testPanelFitsNegativeOriginDisplayAndAvoidsNotchHubBelowTheMenuBar() {
        let visible = CGRect(x: -1710, y: 272, width: 1710, height: 1070)
        let overlay = CGRect(x: -1032, y: 238, width: 700, height: 67)
        let frame = MenuBarOverflow.panelFrame(
            visibleFrame: visible, menuBar: CGRect(x: -1710, y: 238, width: 1710, height: 34),
            anchorX: -100, preferredWidth: 900, occlusions: [overlay])
        XCTAssertTrue(visible.contains(frame))
        XCTAssertGreaterThanOrEqual(frame.minY, overlay.maxY + 8)
        XCTAssertFalse(frame.intersects(overlay))
    }
    func testPanelShrinksOnSmallScreenAndStaysOnItsDisplay() {
        let visible = CGRect(x: 2560, y: -900, width: 500, height: 700)
        let frame = MenuBarOverflow.panelFrame(
            visibleFrame: visible, menuBar: CGRect(x: 2560, y: -930, width: 500, height: 30),
            anchorX: 9000, preferredWidth: 900, occlusions: [])
        XCTAssertTrue(visible.contains(frame))
        XCTAssertLessThan(frame.width, 500)
    }
    func testNormalViewExcludesSystemAndAlwaysHiddenWhileExplicitAllStillRespectsSearch() {
        let items = [item("Visible"), item("Hidden"), item("Always"), item("Clock", bundle: "com.apple.MenuBarAgent")]
        var settings = BarPilotSettings()
        settings.assign(.init(id: "Hidden", visibility: .hidden))
        settings.assign(.init(id: "Always", visibility: .alwaysHidden))
        XCTAssertEqual(MenuBarOverflow.items(items, settings: settings).map(\.id), ["Visible", "Hidden"])
        XCTAssertEqual(
            MenuBarOverflow.items(items, settings: settings, query: "always", includeAlwaysHidden: true).map(\.id),
            ["Always"])
        XCTAssertTrue(MenuBarOverflow.items(items, settings: settings, query: "always").isEmpty)
    }
    func testExistingSettingsKeepAutomaticModeAndExplicitPreferenceRoundTrips() throws {
        let data = Data(
            "{\"schemaVersion\":1,\"managementEnabled\":false,\"assignments\":[],\"groups\":[],\"presets\":[]}".utf8)
        var settings = try JSONDecoder().decode(BarPilotSettings.self, from: data)
        XCTAssertEqual(settings.overflowMode ?? .automatic, .automatic)
        settings.overflowMode = .always
        XCTAssertEqual(
            try JSONDecoder().decode(BarPilotSettings.self, from: JSONEncoder().encode(settings)).overflowMode, .always)
    }
}
