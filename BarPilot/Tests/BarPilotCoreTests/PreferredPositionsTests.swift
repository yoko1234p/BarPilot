import BarPilotCore
import Foundation
import XCTest

final class PreferredPositionsTests: XCTestCase {
    private func item(
        identifier: String?, help: String? = nil, bundle: String = "test.app", executable: String? = nil
    ) -> MenuBarItem {
        MenuBarItem(
            id: "fixture", bundleIdentifier: bundle, applicationName: "Fixture", title: "Unrelated title",
            pid: 1, frame: nil, canActivate: true, hasStableIdentity: true, axIdentifier: identifier, axHelp: help,
            executableName: executable)
    }
    func testExactAutosaveMatchPreservesCaseAndDoesNotGuessOwnerWide() throws {
        let table: [String: Any] = ["status:test.app::Main": 20, "status:test.app::Other": 10]
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(item(identifier: "Main"), in: table), "status:test.app::Main")
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(item(identifier: nil), in: table))
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(item(identifier: nil), in: ["status:test.app::Main": 20]))
    }
    func testSystemModuleResolutionRequiresUniqueExistingNumericKey() throws {
        let siri = item(identifier: "com.apple.menuextra.siri", bundle: "com.apple.systemuiserver")
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(siri, in: ["status:com.apple.systemuiserver::siri": 1]),
            "status:com.apple.systemuiserver::siri")
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(
                siri,
                in: ["status:com.apple.systemuiserver::siri": 1, "module:Siri": 2]))
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(siri, in: ["module:Siri": "unknown"]))
    }
    func testFreshSingletonWidgetCanBindOnlyItsOwnersUniqueNumericPosition() throws {
        let unnamed = item(identifier: nil)
        let table: [String: Any] = ["status:test.app::SavedName": 20, "status:other.app::Other": 10]
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(unnamed, in: table, liveItems: [unnamed]),
            "status:test.app::SavedName")
        let renamed = item(identifier: "AXNameDifferentFromAutosaveName")
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(renamed, in: table, liveItems: [renamed]),
            "status:test.app::SavedName")
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(unnamed, in: table))
    }
    func testSingletonBindingRejectsExtraWidgetsHistoricalKeysAndWrongLiveOwner() {
        let unnamed = item(identifier: nil)
        let single: [String: Any] = ["status:test.app::SavedName": 20]
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(unnamed, in: single, liveItems: [unnamed, unnamed]))
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(unnamed, in: single, liveItems: []))
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(
                unnamed, in: single, liveItems: [item(identifier: nil, bundle: "other.app")]))
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(
                unnamed, in: single.merging(["status:test.app::Old": 5]) { _, new in new }, liveItems: [unnamed]))
        let foreign = item(identifier: "status:other.app::Other")
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(foreign, in: single, liveItems: [foreign]))
        let system = item(identifier: nil, bundle: "com.apple.MenuBarAgent")
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(
                system, in: ["status:com.apple.MenuBarAgent::Other": 10], liveItems: [system]))
    }
    func testThirdPartyIdentifierCannotMoveAnotherOwnerOrSystemModule() {
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(
                item(identifier: "status:other.app::Main"),
                in: ["status:other.app::Main": 20]))
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(item(identifier: "module:Clock"), in: ["module:Clock": 20]))
    }
    func testExecutableOwnerRequiresVerifiedLiveNameAndRejectsCollisions() throws {
        let capture = item(identifier: "capture.status", bundle: "test.capture", executable: "CaptureText")
        let table: [String: Any] = ["status:CaptureText::Item-0": 30]
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(capture, in: table, liveItems: [capture]),
            "status:CaptureText::Item-0")
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(capture, in: table))
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(capture, in: table, liveItems: []))
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(
                item(identifier: nil, bundle: "test.capture"), in: table, liveItems: [capture]))
        let collision = item(identifier: nil, bundle: "other.capture", executable: "CaptureText")
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(capture, in: table, liveItems: [capture, collision]))
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.resolve(
                capture, in: table.merging(["status:test.capture::Other": 10]) { _, new in new }, liveItems: [capture]))
    }
    func testObservedSystemModulesAreOwnerRestricted() throws {
        for (suffix, key) in [("battery", "Battery"), ("wifi", "WiFi"), ("bluetooth", "Bluetooth")] {
            let identifier = "com.apple.menuextra." + suffix
            let table: [String: Any] = ["module:" + key: 10]
            XCTAssertEqual(
                try MenuBarPreferredPositions.resolve(
                    item(identifier: identifier, bundle: "com.apple.MenuBarAgent"), in: table),
                "module:" + key)
            XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(item(identifier: identifier), in: table))
        }
    }
    func testExplicitControlKeyDistinguishesCurrentAndHistoricalOwnerNames() throws {
        let control = item(identifier: "status:test.app::BarPilot.Control", executable: "BarPilot")
        let table: [String: Any] = ["status:test.app::BarPilot.Control": 99, "status:BarPilot::BarPilot.Control": 800]
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(control, in: table, liveItems: [control]),
            "status:test.app::BarPilot.Control")
        let olderOwner = item(identifier: "status:BarPilot::BarPilot.Control", executable: "BarPilot")
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(olderOwner, in: table, liveItems: [olderOwner]),
            "status:BarPilot::BarPilot.Control")
    }
    func testWidgetHelpResolvesSeparatorsButKeepsDistinctWidgets() throws {
        let table: [String: Any] = ["status:test.app::CPU_Mini": 10, "status:test.app::CPU_Label": 10]
        XCTAssertEqual(
            try MenuBarPreferredPositions.resolve(item(identifier: nil, help: "CPU: Mini"), in: table),
            "status:test.app::CPU_Mini")
        XCTAssertThrowsError(try MenuBarPreferredPositions.resolve(item(identifier: nil, help: "CPU"), in: table))
    }
    func testNumericValuesRejectBooleanNanInfinityNegativeAndOverflow() {
        for value: Any in [true, false, Double.nan, Double.infinity, -1, 1_000_000_000, "20"] {
            XCTAssertNil(MenuBarPreferredPositions.numeric(value))
        }
        XCTAssertEqual(MenuBarPreferredPositions.numeric(20.5), 20.5)
    }
    func testLargerPositionMovesLeftAndMidpointKeepsOtherKeys() throws {
        let table: [String: Any] = ["left": 100, "target": 80, "source": 20, "unknown": "shape"]
        let change = try MenuBarPreferredPositions.move("source", before: "target", positions: table)
        XCTAssertEqual(change.proposed, ["source": 90])
        let updated = try change.merging(into: table)
        XCTAssertEqual(updated["left"] as? Int, 100)
        XCTAssertEqual(updated["unknown"] as? String, "shape")
    }
    func testLeftmostAndZeroPositionsRemainNonnegativeIntegers() throws {
        let change = try MenuBarPreferredPositions.move(
            "source", before: "target", positions: ["source": 0, "target": 100])
        XCTAssertEqual(change.proposed["source"], 110)
        try change.validate()
    }
    func testDropAfterUsesFollowingGapAndCanReachLastPosition() throws {
        let table: [String: Any] = ["source": 100, "target": 80, "next": 60, "last": 20]
        let middle = try MenuBarPreferredPositions.move("source", before: "target", positions: table, placement: .after)
        XCTAssertEqual(middle.proposed, ["source": 70])
        let last = try MenuBarPreferredPositions.move("source", before: "last", positions: table, placement: .after)
        XCTAssertEqual(last.proposed, ["source": 10])
        let zero = try MenuBarPreferredPositions.move(
            "source", before: "target", positions: ["source": 10, "target": 0], placement: .after)
        let updated = try zero.merging(into: ["source": 10, "target": 0])
        XCTAssertLessThan(
            try XCTUnwrap(updated["source"].flatMap(MenuBarPreferredPositions.numeric)),
            try XCTUnwrap(updated["target"].flatMap(MenuBarPreferredPositions.numeric)))
    }
    func testAfterPlacementPersistsAndOlderJournalDefaultsToBefore() throws {
        let entry = PreferredPositionJournalEntry(
            itemID: "a", beforeItemID: "b", displayIdentifier: "main",
            change: .init(original: ["a": 2], proposed: ["a": 1]),
            placement: .after)
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(PreferredPositionJournalEntry.self, from: data).placement, .after)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "placement")
        let decoded = try JSONDecoder().decode(
            PreferredPositionJournalEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.placement ?? .before, .before)
    }
    func testGeometryVerificationDistinguishesBothDropEdgesAndRejectsWrongRows() {
        let left = CGRect(x: 100, y: 0, width: 30, height: 24)
        let right = CGRect(x: 130, y: 0, width: 30, height: 24)
        XCTAssertTrue(MenuBarPlacement.before.isSatisfied(source: left, target: right))
        XCTAssertTrue(MenuBarPlacement.after.isSatisfied(source: right, target: left))
        XCTAssertFalse(MenuBarPlacement.after.isSatisfied(source: left, target: right))
        XCTAssertFalse(MenuBarPlacement.before.isSatisfied(source: left, target: left))
        XCTAssertFalse(MenuBarPlacement.before.isSatisfied(source: left, target: right.offsetBy(dx: 0, dy: 30)))
    }
    func testSystemRenumberingMustPreserveStrictPositionOrder() {
        XCTAssertTrue(MenuBarPlacement.before.isSatisfied(sourcePosition: 572.5, targetPosition: 541.5))
        XCTAssertTrue(MenuBarPlacement.after.isSatisfied(sourcePosition: 541.5, targetPosition: 572.5))
        XCTAssertFalse(MenuBarPlacement.before.isSatisfied(sourcePosition: 541.5, targetPosition: 572.5))
        XCTAssertFalse(MenuBarPlacement.before.isSatisfied(sourcePosition: 10, targetPosition: 10))
        XCTAssertFalse(MenuBarPlacement.before.isSatisfied(sourcePosition: .infinity, targetPosition: 0))
        XCTAssertFalse(MenuBarPlacement.after.isSatisfied(sourcePosition: 0, targetPosition: -.infinity))
    }
    func testDenseTableRebalancesExistingKeysWithoutChangingOtherRelativeOrder() throws {
        let table: [String: Any] = ["first": 3, "target": 2, "last": 1, "source": 0, "unknown": ["unchanged": true]]
        let change = try MenuBarPreferredPositions.move("source", before: "target", positions: table)
        let merged = try change.merging(into: table)
        let order = merged.compactMapValues(MenuBarPreferredPositions.numeric).sorted { $0.value > $1.value }.map(\.key)
        XCTAssertEqual(order, ["first", "source", "target", "last"])
        XCTAssertEqual(merged["unknown"] as? [String: Bool], ["unchanged": true])
        XCTAssertTrue(change.proposed.values.allSatisfy { $0 >= 0 && $0.rounded() == $0 })
    }
    func testDenseTiesWithoutObservedIdentityAreNotGuessed() {
        XCTAssertThrowsError(
            try MenuBarPreferredPositions.move(
                "source", before: "target",
                positions: ["first": 3, "target": 3, "last": 2, "source": 0]))
    }
    func testConcurrentChangeBlocksWriteAndRecoveryDoesNotOverwriteNewState() throws {
        let change = PreferredPositionChange(original: ["source": 1], proposed: ["source": 11])
        XCTAssertThrowsError(try change.merging(into: ["source": 2, "other": 20]))
        let updated = try change.merging(into: ["source": 1, "other": 20])
        XCTAssertThrowsError(try change.merging(into: ["source": 12, "other": 25], restoring: true))
        let restored = try change.merging(into: updated.merging(["other": 25]) { _, new in new }, restoring: true)
        XCTAssertEqual(MenuBarPreferredPositions.numeric(restored["source"]!), 1)
        XCTAssertEqual(restored["other"] as? Int, 25)
    }
    func testInterruptedWriteRemainsPendingAndSecondMoveCannotReplaceJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PreferredPositionJournal(directory: directory)
        let change = PreferredPositionChange(original: ["source": 1], proposed: ["source": 11])
        var first = PreferredPositionJournalEntry(
            itemID: "a", beforeItemID: "b", displayIdentifier: "display", change: change)
        try journal.save(first)
        XCTAssertEqual(try journal.load()?.stage, .prepared)
        let second = PreferredPositionJournalEntry(
            itemID: "x", beforeItemID: "y", displayIdentifier: nil, change: change)
        XCTAssertThrowsError(try journal.save(second))
        first.stage = .writeVerified
        try journal.save(first)
        XCTAssertEqual(try journal.load(), first)
        XCTAssertThrowsError(try journal.finish(second.id))
        try journal.finish(first.id)
        XCTAssertNil(try journal.load())
    }
    func testCorruptJournalCannotBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = PreferredPositionJournal(directory: directory)
        let corrupt = Data("broken journal".utf8)
        try corrupt.write(to: journal.url)
        let entry = PreferredPositionJournalEntry(
            itemID: "a", beforeItemID: "b", displayIdentifier: nil,
            change: .init(original: ["a": 0], proposed: ["a": 10]))
        XCTAssertThrowsError(try journal.save(entry))
        XCTAssertEqual(try Data(contentsOf: journal.url), corrupt)
    }
    func testNativeCFPreferencesPathDomainOnlyUpdatesPositionKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("isolated-preferences.plist")
        let root: [String: Any] = [
            MenuBarPreferredPositions.key: ["a": 1, "b": 10], "UnrelatedSetting": ["preserve": "yes"],
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        let original = try PreferredPositionPreferences.read(at: url)
        let change = PreferredPositionChange(original: ["a": 1], proposed: ["a": 20])
        try PreferredPositionPreferences.write(change.merging(into: original), at: url)
        XCTAssertEqual(MenuBarPreferredPositions.numeric(try PreferredPositionPreferences.read(at: url)["a"]!), 20)
        let saved = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(saved["UnrelatedSetting"] as? [String: String], ["preserve": "yes"])
    }
}
