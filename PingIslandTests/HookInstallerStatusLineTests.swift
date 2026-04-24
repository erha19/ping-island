import XCTest
@testable import Ping_Island

final class HookInstallerStatusLineTests: XCTestCase {
    func testInstalledClaudeStatusLineConfigurationKeepsExistingCustomStatusLine() {
        let existingStatusLine: [String: Any] = [
            "type": "command",
            "command": "/usr/local/bin/my-custom-statusline"
        ]

        let configuration = HookInstaller.installedClaudeStatusLineConfiguration(
            preserving: existingStatusLine
        )

        XCTAssertEqual(configuration["type"] as? String, "command")
        XCTAssertEqual(configuration["command"] as? String, "/usr/local/bin/my-custom-statusline")
    }

    func testInstalledClaudeStatusLineConfigurationInstallsManagedStatusLineWhenMissing() {
        let configuration = HookInstaller.installedClaudeStatusLineConfiguration(preserving: nil)

        XCTAssertEqual(configuration["type"] as? String, "command")
        XCTAssertEqual(
            configuration["command"] as? String,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ping-island")
                .appendingPathComponent("bin")
                .appendingPathComponent("island-statusline")
                .path
        )
    }

    func testInstalledClaudeStatusLineConfigurationRefreshesManagedStatusLine() {
        let existingStatusLine: [String: Any] = [
            "type": "command",
            "command": "/Users/example/.ping-island/bin/island-statusline"
        ]

        let configuration = HookInstaller.installedClaudeStatusLineConfiguration(
            preserving: existingStatusLine
        )

        XCTAssertEqual(configuration["type"] as? String, "command")
        XCTAssertEqual(
            configuration["command"] as? String,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ping-island")
                .appendingPathComponent("bin")
                .appendingPathComponent("island-statusline")
                .path
        )
    }
}
