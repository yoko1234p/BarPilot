import BarPilotCore
import XCTest

final class DisplayLayoutTests: XCTestCase {
    func testExactTopologyIsOrderIndependentAndDoesNotMatchSubset() throws {
        let preset = MenuBarPreset(name: "Office", assignments: [])
        let rule = DisplayLayoutRule(displayIDs: ["1:2:3", "4:5:6"], presetID: preset.id)
        XCTAssertTrue(rule.matches(["4:5:6", "1:2:3"])); XCTAssertFalse(rule.matches(["1:2:3"]))
        var settings = BarPilotSettings(); settings.presets = [preset]; settings.displayLayoutRules = [rule]
        try settings.validate()
        let copy = try JSONDecoder().decode(BarPilotSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(copy.automaticDisplayLayouts); XCTAssertEqual(copy.displayLayoutRules, [rule])
        settings.displayLayoutRules?.append(.init(displayIDs: ["4:5:6", "1:2:3"], presetID: preset.id))
        XCTAssertThrowsError(try settings.validate())
        settings.displayLayoutRules = [rule]; settings.presets = []
        XCTAssertThrowsError(try settings.validate())
    }
    func testReasonsDistinguishConcealedSetupPermissionAndUnknownPosition() {
        func reason(_ visibility: MenuBarVisibility = .hidden, enabled: Bool = true, permission: Bool = true, protected: Bool = false, setup: Bool = false, concealed: Bool = true, frame: Bool = true) -> String {
            MenuBarHiddenReason.explain(visibility: visibility, enabled: enabled, permission: permission, protected: protected, setup: setup, expanded: false, temporary: false, concealed: concealed, frameAvailable: frame, unavailable: nil)
        }
        XCTAssertTrue(reason().contains("收納")); XCTAssertTrue(reason(.alwaysHidden).contains("長期隱藏"))
        XCTAssertTrue(reason(protected: true).contains("系統")); XCTAssertTrue(reason(permission: false).contains("權限"))
        XCTAssertTrue(reason(setup: true).contains("暫時顯示")); XCTAssertTrue(reason(enabled: false).contains("未啟用"))
        XCTAssertTrue(reason(concealed: false, frame: false).contains("無法確認"))
    }
    func testSettingsRejectSymlinkWithoutOverwritingItsDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("retain.json"), data = Data("retain this file".utf8)
        try data.write(to: target)
        let store = BarPilotSettingsStore(directory: root)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(BarPilotSettings()))
        XCTAssertEqual(try Data(contentsOf: target), data)
    }
}
