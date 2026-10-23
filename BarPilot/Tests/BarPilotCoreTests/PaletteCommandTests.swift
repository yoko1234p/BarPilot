import BarPilotCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class PaletteCommandTests: XCTestCase {
    func testDisabledFeaturesDoNotExposeHistoryOrConfiguredActions() {
        let clipboard = textEntry("private fixture")
        let widget = ProActionWidget(name: "Configured fixture", action: .shortcut(name: "Synthetic"))
        let rows = PaletteCommands.rows(
            menuBar: menuCommands, clipboardEnabled: false, clipboard: [clipboard], automationEnabled: false,
            widgets: [widget], rules: [])
        XCTAssertEqual(rows.map(\.id), menuCommands.map(\.id))
        XCTAssertTrue(PaletteCommands.filter(rows, query: "private").isEmpty)
        XCTAssertTrue(PaletteCommands.filter(rows, query: "Configured").isEmpty)
    }

    func testUnifiedSearchIncludesTypedHistoryWidgetsAndOnlyEnabledRules() {
        let text = textEntry("Café 會議摘要")
        let widget = ProActionWidget(name: "工作按鈕", action: .showShelf)
        var rule = ProAutomationRule(name: "會議模式", conditions: [], action: .showShelf)
        rule.enabled = true
        let disabled = ProAutomationRule(name: "不可見", conditions: [], action: .showShelf)
        let rows = PaletteCommands.rows(
            menuBar: menuCommands, clipboardEnabled: true, clipboard: [text], automationEnabled: true,
            widgets: [widget], rules: [rule, disabled])
        XCTAssertEqual(
            PaletteCommands.filter(rows, query: "CAFE clipboard").first?.source,
            .clipboard(id: text.id, kind: .text, digest: text.digest))
        XCTAssertEqual(
            PaletteCommands.filter(rows, query: "工作 action").first?.source,
            .widget(id: widget.id, expectedAction: .showShelf))
        XCTAssertEqual(
            PaletteCommands.filter(rows, query: "manual 會議").first?.source,
            .rule(id: rule.id, expectedAction: .showShelf))
        XCTAssertTrue(rows.first { $0.id == "rule:\(rule.id)" }?.subtitle.contains("不檢查條件") == true)
        XCTAssertTrue(PaletteCommands.filter(rows, query: "不可見").isEmpty)
        XCTAssertTrue(PaletteCommands.filter(rows, query: "CAFE missing").isEmpty)
        XCTAssertEqual(PaletteCommands.filter(rows, query: "布局").first?.source, .menuBar(.preset(presetID)))
    }

    func testRefreshPreservesSelectionByIDAndKeyboardNavigationStaysInBounds() {
        let rows = PaletteCommands.rows(
            menuBar: menuCommands, clipboardEnabled: true, clipboard: [textEntry("Synthetic")],
            automationEnabled: false, widgets: [], rules: [])
        var session = PaletteCommandSession()
        session.open()
        session.reload(rows)
        session.select(2)
        let selected = session.selection
        session.reload([rows[2], rows[0], rows[1]])
        XCTAssertEqual(session.selection, selected)
        XCTAssertEqual(session.selectedIndex, 0)
        session.move(-1)
        XCTAssertEqual(session.selectedIndex, 0)
        session.move(100)
        XCTAssertEqual(session.selectedIndex, 2)
        session.reload([rows[2]])
        XCTAssertEqual(session.selection, rows[2])
        session.reload([])
        XCTAssertNil(session.selection)
    }

    func testDismissDropsSelectionAndRejectsDelayedRefresh() {
        let rows = PaletteCommands.rows(
            menuBar: menuCommands, clipboardEnabled: true, clipboard: [textEntry("Synthetic")],
            automationEnabled: false, widgets: [], rules: [])
        var session = PaletteCommandSession()
        session.open()
        let pendingRefreshToken = session.token
        session.reload(rows)
        session.close()
        session.reload(rows)
        XCTAssertFalse(session.active)
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertNil(session.selection)
        XCTAssertNotEqual(session.token, pendingRefreshToken)
        session.open()
        XCTAssertNotEqual(session.token, pendingRefreshToken)
    }

    func testClipboardExecutionRejectsRemovedChangedOrDisabledHistory() throws {
        let entry = textEntry("Synthetic")
        let source = PaletteCommandSource.clipboard(id: entry.id, kind: .text, digest: entry.digest)
        assertError(.clipboardDisabled) {
            try PaletteCommands.clipboardEntry(for: source, enabled: false, entries: [entry])
        }
        assertError(.staleSelection) { try PaletteCommands.clipboardEntry(for: source, enabled: true, entries: []) }
        var changed = entry
        changed.digest = "changed"
        assertError(.staleSelection) {
            try PaletteCommands.clipboardEntry(for: source, enabled: true, entries: [changed])
        }
        changed = entry
        changed.kind = .image
        assertError(.staleSelection) {
            try PaletteCommands.clipboardEntry(for: source, enabled: true, entries: [changed])
        }
        changed = entry
        changed.pinned = true
        XCTAssertTrue(try PaletteCommands.clipboardEntry(for: source, enabled: true, entries: [changed]).pinned)
    }

    func testInvalidUTF8EmptyAndOversizedPayloadsAreRejectedBeforeWriting() throws {
        var entry = textEntry("Synthetic")
        XCTAssertEqual(
            try PaletteCommands.clipboardPayload(for: entry, isFileAvailable: { _ in false }), .text(entry.data))
        for data in [Data(), Data([0xFF, 0xFE]), Data(count: ClipboardHistoryPolicy.maxEntryBytes + 1)] {
            entry.data = data
            let source = PaletteCommandSource.clipboard(id: entry.id, kind: .text, digest: entry.digest)
            assertError(.invalidClipboard) {
                try PaletteCommands.clipboardEntry(for: source, enabled: true, entries: [entry])
            }
            assertError(.invalidClipboard) {
                try PaletteCommands.clipboardPayload(for: entry, isFileAvailable: { _ in false })
            }
        }
    }

    func testFilePayloadRequiresEveryAbsoluteReferenceToStillExist() throws {
        let paths = ["/fixture/notes.txt", "/fixture/日本語.pdf"]
        var entry = ClipboardEntry(
            kind: .files, data: try JSONEncoder().encode(paths), summary: "Fixture files", digest: "files")
        XCTAssertEqual(
            try PaletteCommands.clipboardPayload(for: entry, isFileAvailable: { paths.contains($0) }), .files(paths))
        assertError(.missingClipboardFiles) {
            try PaletteCommands.clipboardPayload(for: entry, isFileAvailable: { $0 == paths[0] })
        }
        for invalid in [[], ["relative.txt"], ["/fixture/valid", "relative.txt"], ["/fixture/with\0null"]] as [[String]]
        {
            entry.data = try JSONEncoder().encode(invalid)
            var availabilityChecked = false
            assertError(.invalidClipboard) {
                try PaletteCommands.clipboardPayload(
                    for: entry,
                    isFileAvailable: { _ in
                        availabilityChecked = true
                        return true
                    })
            }
            XCTAssertFalse(availabilityChecked)
        }
        entry.data = Data("not json".utf8)
        assertError(.invalidClipboard) {
            try PaletteCommands.clipboardPayload(for: entry, isFileAvailable: { _ in true })
        }
    }

    func testPNGIsDecodedAndOversizedDimensionsOrCorruptionAreRejected() throws {
        let png = try imageData(width: 2, type: UTType.png.identifier)
        var entry = ClipboardEntry(kind: .image, data: png, summary: "Synthetic image", digest: "png")
        XCTAssertEqual(try PaletteCommands.clipboardPayload(for: entry, isFileAvailable: { _ in false }), .png(png))
        for invalid in [
            Data("not an image".utf8), Data(png.prefix(20)),
            try imageData(width: 4097, type: UTType.png.identifier),
            try imageData(width: 2, type: UTType.jpeg.identifier),
        ] {
            entry.data = invalid
            assertError(.invalidClipboard) {
                try PaletteCommands.clipboardPayload(for: entry, isFileAvailable: { _ in false })
            }
        }
    }

    func testAutomationNeedsAnEnabledServiceAndUnchangedCurrentAction() throws {
        var widget = ProActionWidget(name: "Synthetic widget", action: .shortcut(name: "Original"))
        let source = PaletteCommandSource.widget(id: widget.id, expectedAction: widget.action)
        XCTAssertEqual(
            try PaletteCommands.automationAction(
                for: source, enabled: true, running: false, widgets: [widget], rules: []), widget.action)
        assertError(.automationDisabled) {
            try PaletteCommands.automationAction(
                for: source, enabled: false, running: false, widgets: [widget], rules: [])
        }
        assertError(.automationBusy) {
            try PaletteCommands.automationAction(
                for: source, enabled: true, running: true, widgets: [widget], rules: [])
        }
        widget.action = .shortcut(name: "Changed")
        assertError(.changedAction) {
            try PaletteCommands.automationAction(
                for: source, enabled: true, running: false, widgets: [widget], rules: [])
        }
        assertError(.changedAction) {
            try PaletteCommands.automationAction(for: source, enabled: true, running: false, widgets: [], rules: [])
        }
    }

    func testRuleDisabledAfterSearchCannotExecuteItsManualAction() {
        var rule = ProAutomationRule(name: "Synthetic rule", conditions: [], action: .showShelf)
        rule.enabled = true
        let source = PaletteCommandSource.rule(id: rule.id, expectedAction: rule.action)
        rule.enabled = false
        assertError(.changedAction) {
            try PaletteCommands.automationAction(for: source, enabled: true, running: false, widgets: [], rules: [rule])
        }
    }

    func testActionsValidatePresetShelfAndShortcutConfiguration() throws {
        assertError(.missingPreset) {
            try PaletteCommands.validate(
                action: .preset(presetID), presets: [], shelfEnabled: false, isReadableScript: { _ in false })
        }
        assertError(.shelfDisabled) {
            try PaletteCommands.validate(
                action: .showShelf, presets: [], shelfEnabled: false, isReadableScript: { _ in false })
        }
        for name in [" \n", "null\0name", String(repeating: "x", count: 201)] {
            assertError(.invalidShortcut) {
                try PaletteCommands.validate(
                    action: .shortcut(name: name), presets: [], shelfEnabled: false, isReadableScript: { _ in false })
            }
        }
        try PaletteCommands.validate(
            action: .preset(presetID), presets: [presetID], shelfEnabled: false, isReadableScript: { _ in false })
        try PaletteCommands.validate(
            action: .showShelf, presets: [], shelfEnabled: true, isReadableScript: { _ in false })
        try PaletteCommands.validate(
            action: .shortcut(name: "Synthetic"), presets: [], shelfEnabled: false, isReadableScript: { _ in false })
    }

    func testScriptsRejectMissingFilesUnsupportedTypesAndInvalidArguments() throws {
        for (path, arguments) in [
            ("relative.sh", []), ("/fixture/script.app", []), ("/fixture/script\0.sh", []),
            ("/fixture/script.sh", ["null\0argument"]), ("/fixture/script.sh", Array(repeating: "x", count: 51)),
            ("/fixture/script.sh", [String(repeating: "x", count: 4097)]),
        ] as [(String, [String])] {
            assertError(.invalidScript) {
                try PaletteCommands.validate(
                    action: .localScript(path: path, arguments: arguments), presets: [],
                    shelfEnabled: false, isReadableScript: { _ in true })
            }
        }
        assertError(.invalidScript) {
            try PaletteCommands.validate(
                action: .localScript(path: "/fixture/script.sh", arguments: []), presets: [],
                shelfEnabled: false, isReadableScript: { _ in false })
        }
        try PaletteCommands.validate(
            action: .localScript(path: "/fixture/script.sh", arguments: ["literal $(argument)"]),
            presets: [], shelfEnabled: false, isReadableScript: { $0 == "/fixture/script.sh" })
    }

    private let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var menuCommands: [MenuBarCommand] {
        [
            MenuBarCommand(id: "icon", title: "Fixture App", subtitle: "圖示", kind: .item("fixture.icon")),
            MenuBarCommand(id: "preset", title: "Fixture layout", subtitle: "布局", kind: .preset(presetID)),
        ]
    }
    private func textEntry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(kind: .text, data: Data(text.utf8), summary: text, digest: text)
    }
    private func assertError<T>(
        _ expected: PaletteCommandError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? PaletteCommandError, expected, file: file, line: line)
            XCTAssertFalse($0.localizedDescription.isEmpty, file: file, line: line)
        }
    }
    private func imageData(width: Int, type: String) throws -> Data {
        let pixels = Data(repeating: 255, count: width * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
