import BarPilotCore
import XCTest

final class StatusControlTests: XCTestCase {
    func testOrdinaryIconClickRevealsOrConcealsItemsAndDisabledManagementNeverOpensWindow() {
        for expanded in [false, true] {
            XCTAssertEqual(
                BarPilotStatusControl.action(
                    rightClick: false, control: false, option: false,
                    managementEnabled: true, expanded: expanded), expanded ? .conceal : .reveal)
            XCTAssertEqual(
                BarPilotStatusControl.action(
                    rightClick: false, control: false, option: false,
                    managementEnabled: false, expanded: expanded), .requiresManagement)
        }
    }
    func testControlAndRightClickOpenMenuAndOptionSearches() {
        XCTAssertEqual(
            BarPilotStatusControl.action(
                rightClick: false, control: true, option: true,
                managementEnabled: true, expanded: false), .menu)
        XCTAssertEqual(
            BarPilotStatusControl.action(
                rightClick: true, control: false, option: false,
                managementEnabled: false, expanded: false), .menu)
        XCTAssertEqual(
            BarPilotStatusControl.action(
                rightClick: false, control: false, option: true,
                managementEnabled: true, expanded: false), .search)
    }
}
