import BarPilotCore
import Foundation
import XCTest

final class PresentationCommandTests: XCTestCase {
    func testPresentationCannotOverwriteUnrestoredVerifiedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MenuBarPresentationStore(directory: directory)
        let first = MenuBarPresentationSnapshot(
            assignments: [MenuBarAssignment(id: "app", positionVerified: true)], wasExpanded: true, wasSetupMode: false)
        let second = MenuBarPresentationSnapshot(
            assignments: [MenuBarAssignment(id: "other", positionVerified: true)], wasExpanded: false,
            wasSetupMode: false)
        try store.saveNew(first)
        XCTAssertThrowsError(try store.saveNew(second))
        XCTAssertEqual(try MenuBarPresentationStore(directory: directory).load(), first)
        XCTAssertThrowsError(try store.finish(second.id))
        XCTAssertEqual(try store.load(), first)
    }
    func testPresentationRejectsUnverifiedPositionsAndCompletesOnlyMatchingSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MenuBarPresentationStore(directory: directory)
        XCTAssertThrowsError(
            try store.saveNew(
                MenuBarPresentationSnapshot(
                    assignments: [MenuBarAssignment(id: "guessed")], wasExpanded: false, wasSetupMode: false)))
        XCTAssertNil(try store.load())
        let verified = MenuBarPresentationSnapshot(
            assignments: [MenuBarAssignment(id: "real", visibility: .hidden, positionVerified: true)],
            wasExpanded: false, wasSetupMode: false)
        try store.saveNew(verified)
        try store.finish(verified.id)
        XCTAssertNil(try store.load())
    }
    func testCommandSearchFindsPresetsAndActionsWithClearKinds() {
        let preset = UUID()
        let commands = [
            MenuBarCommand(id: "preset", title: "工作模式", subtitle: "布局", kind: .preset(preset)),
            MenuBarCommand(
                id: "restore", title: MenuBarMainAction.restorePresentation.title, subtitle: "動作",
                keywords: MenuBarMainAction.restorePresentation.keywords, kind: .action(.restorePresentation)),
        ]
        XCTAssertEqual(MenuBarCommandSearch.filter(commands, query: "工作 布局").first?.kind, .preset(preset))
        XCTAssertEqual(
            MenuBarCommandSearch.filter(commands, query: "restore").first?.kind, .action(.restorePresentation))
        XCTAssertTrue(MenuBarCommandSearch.filter(commands, query: "missing").isEmpty)
    }
}
