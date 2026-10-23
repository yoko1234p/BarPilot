import BarPilotCore
import CoreGraphics
import XCTest

final class ControlOrderTests: XCTestCase {
    private func item(_ id: String, x: Double, system: Bool = false, display: String = "main") -> MenuBarItem {
        MenuBarItem(
            id: id, bundleIdentifier: (system ? "com.apple." : "test.") + id,
            applicationName: id, title: id, pid: 1, frame: CGRect(x: x, y: 0, width: 24, height: 24),
            canActivate: true, hasStableIdentity: true, displayIdentifier: display)
    }
    func testControlFollowsLastApplicationWhileKeepingSystemClusterRightmost() {
        let apps = [item("first", x: 100), item("last", x: 200)]
        let system = [item("wifi", x: 250, system: true), item("clock", x: 280, system: true)]
        XCTAssertEqual(MenuBarControlOrder.target(for: item("control", x: 50), in: apps + system)?.id, "last")
        XCTAssertNil(MenuBarControlOrder.target(for: item("control", x: 225), in: apps + system))
        XCTAssertEqual(MenuBarControlOrder.target(for: item("control", x: 310), in: apps + system)?.id, "last")
    }
    func testOtherDisplaysAndSystemWidgetsDoNotBecomeTheApplicationAnchor() {
        let items = [
            item("last", x: 200), item("clock", x: 280, system: true), item("external", x: 500, display: "external"),
        ]
        XCTAssertEqual(MenuBarControlOrder.target(for: item("control", x: 100), in: items)?.id, "last")
        XCTAssertNil(MenuBarControlOrder.target(for: item("control", x: 100), in: [items[1]]))
    }
}
