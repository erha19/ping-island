import XCTest
@testable import Ping_Island

final class HookInstallerAutoInstallTests: XCTestCase {
    func testDefaultEnabledManageableProfilesOnlyIncludesAutoInstallProfiles() {
        let profileIDs = Set(HookInstaller.defaultEnabledManageableProfiles().map { $0.id })

        XCTAssertTrue(profileIDs.contains("claude-hooks"))
        XCTAssertFalse(profileIDs.contains("codex-hooks"))
        XCTAssertFalse(profileIDs.contains("qoder-hooks"))
        XCTAssertFalse(profileIDs.contains("qoderwork-hooks"))
        XCTAssertFalse(profileIDs.contains("openclaw-hooks"))
    }

    func testOptionalAgentProfilesDoNotAutoInstallOnFirstRun() {
        XCTAssertFalse(ClientProfileRegistry.managedHookProfile(id: "codex-hooks")?.autoInstallOnFirstRun ?? true)
        XCTAssertFalse(ClientProfileRegistry.managedHookProfile(id: "qoder-hooks")?.autoInstallOnFirstRun ?? true)
        XCTAssertFalse(ClientProfileRegistry.managedHookProfile(id: "qoderwork-hooks")?.autoInstallOnFirstRun ?? true)
        XCTAssertFalse(ClientProfileRegistry.managedHookProfile(id: "openclaw-hooks")?.autoInstallOnFirstRun ?? true)
    }
}
