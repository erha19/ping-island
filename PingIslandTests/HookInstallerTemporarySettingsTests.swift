import XCTest
@testable import Ping_Island

final class HookInstallerTemporarySettingsTests: XCTestCase {
    func testCreateTemporarySettingsFileIncludesClaudeHookEvents() throws {
        let settingsURL = try XCTUnwrap(HookInstaller.createTemporarySettingsFile(for: "claude-hooks"))
        defer { HookInstaller.removeTemporarySettingsFile(at: settingsURL) }

        let data = try Data(contentsOf: settingsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["Stop"])
    }

    func testCreateTemporaryQoderSettingsQuotesClientName() throws {
        let settingsURL = try XCTUnwrap(HookInstaller.createTemporarySettingsFile(for: "qoder-cli-hooks"))
        defer { HookInstaller.removeTemporarySettingsFile(at: settingsURL) }

        let data = try Data(contentsOf: settingsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let command = try XCTUnwrap((preToolUse.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)

        XCTAssertTrue(command.contains("--client-name 'Qoder CLI'"), command)
    }
}
