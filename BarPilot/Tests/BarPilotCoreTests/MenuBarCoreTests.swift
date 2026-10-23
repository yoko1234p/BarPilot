import BarPilotCore
import CoreGraphics
import Foundation
import XCTest

final class MenuBarCoreTests: XCTestCase {
    func testIdentityIsStableAcrossRelaunchAndDuplicateTitlesRemainDistinct() {
        let first = MenuBarIdentity.make(
            bundle: "example.app", identifier: "sync", description: "同步", title: "", occurrence: 0)
        let relaunched = MenuBarIdentity.make(
            bundle: "example.app", identifier: "sync", description: "Synchronize", title: nil, occurrence: 0)
        XCTAssertEqual(first.id, relaunched.id)
        XCTAssertTrue(first.stable)
        XCTAssertNotEqual(
            first.id,
            MenuBarIdentity.make(bundle: "example.app", identifier: "sync", description: nil, title: nil, occurrence: 1)
                .id)
        XCTAssertFalse(
            MenuBarIdentity.make(bundle: "example.app", identifier: nil, description: "", title: nil, occurrence: 0)
                .stable)
    }

    func testSearchMatchesAllWordsAcrossApplicationAndItemLabels() {
        let items = [
            MenuBarItem(
                id: "a", bundleIdentifier: "test.mail", applicationName: "Mail", title: "收件匣", pid: 1, frame: nil,
                canActivate: true, hasStableIdentity: true),
            MenuBarItem(
                id: "b", bundleIdentifier: "test.sync", applicationName: "Sync", title: "同步", pid: 2, frame: nil,
                canActivate: false, hasStableIdentity: true),
        ]
        XCTAssertEqual(MenuBarSearch.filter(items, query: "mail 收件").map(\.id), ["a"])
        XCTAssertTrue(MenuBarSearch.filter(items, query: "mail 同步").isEmpty)
        XCTAssertEqual(MenuBarSearch.filter(items, query: "").count, 2)
    }

    func testDividerMoveTargetsAndClassificationOnNegativeOriginDisplay() throws {
        let hidden = CGRect(x: -200, y: -40, width: 22, height: 25)
        let always = CGRect(x: -400, y: -40, width: 22, height: 25)
        XCTAssertGreaterThan(
            try XCTUnwrap(MenuBarMovePlan.target(visibility: .visible, hiddenDivider: hidden, alwaysDivider: always)).x,
            hidden.maxX)
        XCTAssertLessThan(
            try XCTUnwrap(
                MenuBarMovePlan.target(visibility: .alwaysHidden, hiddenDivider: hidden, alwaysDivider: always)
            ).x, always.minX)
        for (x, expected) in [(-100.0, MenuBarVisibility.visible), (-300, .hidden), (-500, .alwaysHidden)] {
            XCTAssertEqual(
                MenuBarMovePlan.classify(
                    frame: CGRect(x: x, y: -40, width: 24, height: 25), hiddenDivider: hidden, alwaysDivider: always),
                expected)
        }
        XCTAssertNil(MenuBarMovePlan.target(visibility: .hidden, hiddenDivider: always, alwaysDivider: hidden))
    }

    func testLayoutsPresetsAndGroupsPersistWithoutProcessIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BarPilotSettingsStore(directory: directory)
        var settings = BarPilotSettings()
        let group = MenuBarGroup(name: "工作")
        settings.groups = [group]
        settings.assign(
            MenuBarAssignment(
                id: "test|sync|0", visibility: .hidden, groupID: group.id, order: 2, positionVerified: true))
        settings.presets = [MenuBarPreset(name: "工作模式", assignments: settings.assignments)]
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        XCTAssertFalse(try String(contentsOf: store.url, encoding: .utf8).contains("pid"))
    }

    func testInvalidSettingsCannotReplaceLastValidLayout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BarPilotSettingsStore(directory: directory)
        let original = BarPilotSettings()
        try store.save(original)
        var invalid = original
        invalid.assignments = [MenuBarAssignment(id: "a", groupID: UUID())]
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load(), original)
        invalid.schemaVersion = 99
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load(), original)
    }

    func testPerDisplayPresetKeepsMissingItemsUntilAppOrDisplayReturns() throws {
        var settings = BarPilotSettings()
        let missing = MenuBarAssignment(id: "not-running|status|0", visibility: .hidden, order: 3)
        settings.presets = [MenuBarPreset(name: "外置螢幕", assignments: [missing], displayIdentifier: "monitor-serial")]
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BarPilotSettings.self, from: encoded)
        XCTAssertEqual(decoded.presets[0].displayIdentifier, "monitor-serial")
        XCTAssertEqual(decoded.presets[0].assignments, [missing])
        XCTAssertTrue(decoded.assignments.isEmpty)
    }
}
