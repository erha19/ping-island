import Foundation
import XCTest
@testable import NotchCode

final class SkillUsageStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ping-island-skill-usage-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordUseIncrementsAndPersists() {
        XCTAssertEqual(SkillUsageStore.useCount(folderName: "demo-skill", defaults: defaults), 0)
        XCTAssertEqual(SkillUsageStore.recordUse(folderName: "demo-skill", defaults: defaults), 1)
        XCTAssertEqual(SkillUsageStore.recordUse(folderName: "demo-skill", defaults: defaults), 2)
        XCTAssertEqual(SkillUsageStore.useCount(folderName: "demo-skill", defaults: defaults), 2)
        XCTAssertEqual(SkillUsageStore.load(defaults: defaults).use_counts["demo-skill"], 2)
    }

    func testBlankFolderNameIsIgnored() {
        XCTAssertEqual(SkillUsageStore.recordUse(folderName: "  ", defaults: defaults), 0)
        XCTAssertTrue(SkillUsageStore.load(defaults: defaults).use_counts.isEmpty)
    }
}
