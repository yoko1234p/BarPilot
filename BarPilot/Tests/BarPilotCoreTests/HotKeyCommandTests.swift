import BarPilotCore
import XCTest

final class HotKeyCommandTests: XCTestCase {
    func testSearchAndRecoveryPacketsRouteToDistinctCommands() {
        XCTAssertEqual(BarPilotHotKeyCommand.decode(signature: BarPilotHotKeyCommand.signature, id: 1), .search)
        XCTAssertEqual(BarPilotHotKeyCommand.decode(signature: BarPilotHotKeyCommand.signature, id: 2), .recover)
        XCTAssertNil(BarPilotHotKeyCommand.decode(signature: 0, id: 2))
        XCTAssertNil(BarPilotHotKeyCommand.decode(signature: BarPilotHotKeyCommand.signature, id: 99))
    }
}
