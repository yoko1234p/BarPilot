import BarPilotCore
import Foundation
import XCTest

final class MenuBarListFilterTests: XCTestCase {
    private func item(_ name: String, bundle: String? = nil, display: String? = "main") -> MenuBarItem {
        MenuBarItem(
            id: name, bundleIdentifier: bundle ?? "test." + name, applicationName: name, title: name,
            pid: 1, frame: nil, canActivate: true, hasStableIdentity: true, displayIdentifier: display)
    }
    func testCategoriesAreExclusiveAndIncludeMandatorySystemItemsAsVisible() {
        let items = [item("Visible"), item("Hidden"), item("Always"), item("Clock", bundle: "com.apple.MenuBarAgent")]
        var settings = BarPilotSettings()
        settings.assign(.init(id: "Hidden", visibility: .hidden))
        settings.assign(.init(id: "Always", visibility: .alwaysHidden))
        settings.assign(.init(id: "Clock", visibility: .alwaysHidden))
        XCTAssertEqual(
            MenuBarListFilter.items(items, settings: settings, visibility: .visible).map(\.id), ["Visible", "Clock"])
        XCTAssertEqual(MenuBarListFilter.items(items, settings: settings, visibility: .hidden).map(\.id), ["Hidden"])
        XCTAssertEqual(
            MenuBarListFilter.items(items, settings: settings, visibility: .alwaysHidden).map(\.id), ["Always"])
        XCTAssertEqual(MenuBarListFilter.items(items, settings: settings).count, 4)
        XCTAssertEqual(
            MenuBarListFilter.items(items, settings: settings, visibility: .alwaysHidden, native: false).map(\.id),
            ["Always", "Clock"])
    }
    func testCategoryIntersectsSearchDisplayAndGroupWithoutChangingTheInventory() {
        let items = [
            item("Capture Main"), item("Capture Second", display: "second"), item("Other"),
            item("Capture Unknown", display: nil),
        ]
        let group = MenuBarGroup(name: "Tools")
        var settings = BarPilotSettings()
        settings.groups = [group]
        for value in items { settings.assign(.init(id: value.id, visibility: .hidden, groupID: group.id)) }
        XCTAssertEqual(
            MenuBarListFilter.items(
                items, settings: settings, query: "capture", display: "main", group: group.id, visibility: .hidden
            ).map(\.id), ["Capture Main", "Capture Unknown"])
        XCTAssertTrue(
            MenuBarListFilter.items(
                items, settings: settings, query: "capture", display: "main", group: group.id, visibility: .visible
            ).isEmpty)
        XCTAssertEqual(MenuBarListFilter.items(items, settings: settings, query: "capture").count, 3)
        XCTAssertEqual(items.count, 4)
    }
}
