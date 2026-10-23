import BarPilotCore
import CoreGraphics
import Foundation
import XCTest

final class MoveJournalTests: XCTestCase {
    func testCrashRecordRetainsOriginalCursorAndIntendedRegionAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = MenuBarMoveJournalEntry(
            itemID: "app|sync|0", desiredVisibility: .hidden, displayIdentifier: "external",
            cursor: CGPoint(x: -900, y: 500), sourceFrame: CGRect(x: -300, y: 0, width: 24, height: 24))
        try MenuBarMoveJournal(directory: directory).begin(entry)
        XCTAssertEqual(try MenuBarMoveJournal(directory: directory).pending(), entry)
    }
    func testNewMovementCannotOverwriteAnUnresolvedCrashRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MenuBarMoveJournal(directory: directory)
        let first = MenuBarMoveJournalEntry(
            itemID: "first", desiredVisibility: .hidden, displayIdentifier: nil, cursor: .zero, sourceFrame: .zero)
        let second = MenuBarMoveJournalEntry(
            itemID: "second", desiredVisibility: .visible, displayIdentifier: nil, cursor: .zero, sourceFrame: .zero)
        try journal.begin(first)
        XCTAssertThrowsError(try journal.begin(second))
        XCTAssertThrowsError(try journal.complete(second.id))
        XCTAssertEqual(try journal.pending(), first)
    }
    func testStageChangesAreAtomicAndVerifiedCompletionRemovesOnlyJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MenuBarMoveJournal(directory: directory)
        let settings = BarPilotSettingsStore(directory: directory)
        try settings.save(BarPilotSettings())
        var entry = MenuBarMoveJournalEntry(
            itemID: "item", desiredVisibility: .alwaysHidden, displayIdentifier: nil, cursor: .zero, sourceFrame: .zero)
        try journal.begin(entry)
        entry.stage = .nativeMoveFinished
        try journal.update(entry)
        XCTAssertEqual(try journal.pending()?.stage, .nativeMoveFinished)
        entry.stage = .verified
        try journal.update(entry)
        try journal.complete(entry.id)
        XCTAssertNil(try journal.pending())
        XCTAssertEqual(try settings.load(), BarPilotSettings())
    }
}
