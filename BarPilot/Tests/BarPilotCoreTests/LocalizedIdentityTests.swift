import BarPilotCore
import XCTest

final class LocalizedIdentityTests: XCTestCase {
    func testOwnStatusIdentityDoesNotDependOnTranslatedMenuTitle() {
        let bundle = "local.pakwingho.edgenotes"
        let chinese = MenuBarIdentity.make(bundle: bundle, identifier: nil, description: "側邊筆記", title: nil, occurrence: 0)
        let english = MenuBarIdentity.make(bundle: bundle, identifier: nil, description: "Side notes", title: nil, occurrence: 0)
        XCTAssertEqual(chinese.id, english.id)
        XCTAssertTrue(chinese.stable)
    }

    func testSavedLegacyIdentityAndLayoutArePreservedWithoutRewritingSettings() {
        let id = "local.pakwingho.edgenotes|%E5%81%B4%E9%82%8A%E7%AD%86%E8%A8%98|0"
        var settings = BarPilotSettings()
        settings.assign(.init(id: id, visibility: .hidden, order: 4))
        settings.presets = [.init(name: "My layout", assignments: settings.assignments)]
        let previous = settings
        let aliases = MenuBarIdentity.savedOwnStatusIdentifiers(in: settings)
        let identity = MenuBarIdentity.make(
            bundle: "local.pakwingho.edgenotes", identifier: nil, description: "Side notes", title: nil,
            occurrence: 0, savedOwnIdentifiers: aliases)
        XCTAssertEqual(identity.id, id)
        XCTAssertEqual(settings.assignment(for: identity.id).visibility, .hidden)
        XCTAssertEqual(settings, previous)
    }

    func testConflictingAliasesAndOtherApplicationsAreNotGuessed() {
        let bundle = "local.pakwingho.edgenotes"
        var settings = BarPilotSettings()
        settings.assign(.init(id: bundle + "|old|0", visibility: .hidden))
        settings.assign(.init(id: bundle + "|other|0", visibility: .visible))
        XCTAssertNil(MenuBarIdentity.savedOwnStatusIdentifiers(in: settings)[bundle])
        let foreign = MenuBarIdentity.make(bundle: "third.party", identifier: nil, description: "One", title: nil, occurrence: 0)
        XCTAssertEqual(foreign.id, "third.party|one|0")
    }
}
