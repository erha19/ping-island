import XCTest
@testable import Ping_Island

final class HookProfileStabilityTests: XCTestCase {
    func testOptionalAgentPreToolUseHooksDoNotBlockHost() throws {
        let profileIDs = [
            "kimi-hooks",
            "factory-hooks",
            "trae-hooks",
            "stepfun-hooks",
            "antigravity-hooks",
            "qoderwork-hooks",
        ]

        for profileID in profileIDs {
            let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: profileID), profileID)
            let preToolUse = try XCTUnwrap(
                profile.events.first { $0.name == "PreToolUse" },
                "\(profileID) should install PreToolUse"
            )
            XCTAssertNil(preToolUse.timeout, "\(profileID) PreToolUse must not add a long host-blocking timeout")

            let permissionRequest = profile.events.first { $0.name == "PermissionRequest" }
            XCTAssertEqual(
                permissionRequest?.timeout,
                86_400,
                "\(profileID) should reserve long waits for explicit user permission events only"
            )
        }
    }
}
