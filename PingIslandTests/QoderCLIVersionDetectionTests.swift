import XCTest
@testable import Ping_Island

final class QoderCLIVersionDetectionTests: XCTestCase {
    func testQoderCLIVersionParserAcceptsPlainVersion() {
        XCTAssertEqual(HookInstaller.qoderCLIVersion(from: "0.2.6\n"), "0.2.6")
    }

    func testQoderCLIVersionParserAcceptsCommandLabel() {
        XCTAssertEqual(HookInstaller.qoderCLIVersion(from: "qodercli version 0.3.1"), "0.3.1")
    }

    func testQoderCLIVersionComparisonUsesNumericComponents() {
        XCTAssertEqual(HookInstaller.compareSemanticVersions("0.2.6", "0.2.5"), .orderedDescending)
        XCTAssertEqual(HookInstaller.compareSemanticVersions("0.2.5", "0.2.5"), .orderedSame)
        XCTAssertEqual(HookInstaller.compareSemanticVersions("0.2.4", "0.2.5"), .orderedAscending)
        XCTAssertEqual(HookInstaller.compareSemanticVersions("0.10.0", "0.2.5"), .orderedDescending)
    }

    func testQoderCLIClaudeHooksSupportStartsAtMinimumVersion() {
        XCTAssertTrue(HookInstaller.qoderCLIClaudeHooksSupported(version: "0.2.5"))
        XCTAssertTrue(HookInstaller.qoderCLIClaudeHooksSupported(version: "0.2.6"))
        XCTAssertFalse(HookInstaller.qoderCLIClaudeHooksSupported(version: "0.2.4"))
    }

    func testQoderCLIExecutableURLUsesLocalBinUnderHome() throws {
        let home = URL(fileURLWithPath: "/Users/example")

        let url = try XCTUnwrap(HookInstaller.qoderCLIExecutableURL(homeDirectory: home))

        XCTAssertEqual(url.path, "/Users/example/.local/bin/qodercli")
    }

    func testQoderCNCLIExecutableURLUsesOfficialCommandName() throws {
        let home = URL(fileURLWithPath: "/Users/example")

        let url = try XCTUnwrap(HookInstaller.qoderCNCLIExecutableURL(homeDirectory: home))

        XCTAssertEqual(url.path, "/Users/example/.local/bin/qoderclicn")
    }

    func testQoderHookRefreshPreservesUnrelatedSettings() throws {
        let qoderIDEProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "qoder-hooks"))
        let qoderCLIProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "qoder-cli-hooks"))
        let existing = """
        {
          "env": {"KEEP": "1"},
          "theme": "dark",
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "*",
                "hooks": [{"type": "command", "command": "/usr/bin/printf keep"}]
              },
              {
                "matcher": "*",
                "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder"}]
              }
            ],
            "PostToolUseFailure": [
              {
                "matcher": "*",
                "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder"}]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let ideData = HookInstaller.updatedConfigurationData(
            existingData: existing,
            profile: qoderIDEProfile,
            customCommand: "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder",
            installing: true
        )
        let data = HookInstaller.updatedConfigurationData(
            existingData: ideData,
            profile: qoderCLIProfile,
            customCommand: "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder-cli --client-name Qoder CLI --client-origin cli --client-originator Qoder",
            installing: true
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((json["env"] as? [String: String])?["KEEP"], "1")
        XCTAssertEqual(json["theme"] as? String, "dark")

        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["SessionEnd"])
        XCTAssertNotNil(hooks["PreCompact"])
        XCTAssertNotNil(hooks["PostToolUseFailure"])

        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let commands = preToolUse.compactMap { entry in
            ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        }
        XCTAssertTrue(commands.first?.contains("--client-kind qoder-cli") == true)
        XCTAssertTrue(commands.contains { $0.contains("--client-kind qoder") && !$0.contains("--client-kind qoder-cli") })
        XCTAssertTrue(commands.contains("/usr/bin/printf keep"))
        XCTAssertEqual(
            commands.filter { $0.contains("/.ping-island/bin/ping-island-bridge") }.count,
            2
        )
        let managedPreToolUseHook = try XCTUnwrap((preToolUse.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(managedPreToolUseHook["timeout"] as? Int, 86_400)
    }

    func testQoderCNSharedSettingsKeepDesktopAndCLIHooksIndependent() throws {
        let desktopProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "qoder-cn-hooks"))
        let cliProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "qoder-cn-cli-hooks"))
        let desktopCommand = "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder-cn --client-name 'Qoder CN' --client-originator 'Qoder CN'"
        let cliCommand = "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder-cn-cli --client-name 'Qoder CN CLI' --client-origin cli --client-originator 'Qoder CN'"

        let desktopData = HookInstaller.updatedConfigurationData(
            existingData: #"{"theme":"dark"}"#.data(using: .utf8),
            profile: desktopProfile,
            customCommand: desktopCommand,
            installing: true
        )
        let combinedData = HookInstaller.updatedConfigurationData(
            existingData: desktopData,
            profile: cliProfile,
            customCommand: cliCommand,
            installing: true
        )
        let combinedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: combinedData) as? [String: Any])
        let combinedHooks = try XCTUnwrap(combinedJSON["hooks"] as? [String: Any])
        let combinedPreToolUse = try XCTUnwrap(combinedHooks["PreToolUse"] as? [[String: Any]])
        let combinedCommands = combinedPreToolUse.compactMap { entry in
            (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String
        }

        XCTAssertEqual(combinedJSON["theme"] as? String, "dark")
        XCTAssertTrue(combinedCommands.first?.contains("--client-kind qoder-cn-cli") == true)
        XCTAssertTrue(combinedCommands.contains { $0.contains("--client-kind qoder-cn ") })

        let cliOnlyData = HookInstaller.updatedConfigurationData(
            existingData: combinedData,
            profile: desktopProfile,
            customCommand: desktopCommand,
            installing: false
        )
        let cliOnlyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: cliOnlyData) as? [String: Any])
        let cliOnlyHooks = try XCTUnwrap(cliOnlyJSON["hooks"] as? [String: Any])
        let cliOnlyPreToolUse = try XCTUnwrap(cliOnlyHooks["PreToolUse"] as? [[String: Any]])
        let cliOnlyCommands = cliOnlyPreToolUse.compactMap { entry in
            (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String
        }

        XCTAssertFalse(cliOnlyCommands.contains { $0.contains("--client-kind qoder-cn ") })
        XCTAssertTrue(cliOnlyCommands.contains { $0.contains("--client-kind qoder-cn-cli") })
    }

    func testCodeBuddyCLIHookRefreshPreservesCodeBuddyIDEHooks() throws {
        let codeBuddyProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "codebuddy-hooks"))
        let codeBuddyCLIProfile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "codebuddy-cli-hooks"))
        let existing = """
        {
          "theme": "dark",
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "*",
                "hooks": [{"type": "command", "command": "/usr/bin/printf keep"}]
              },
              {
                "matcher": "*",
                "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind codebuddy --client-name CodeBuddy --client-originator CodeBuddy"}]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let ideData = HookInstaller.updatedConfigurationData(
            existingData: existing,
            profile: codeBuddyProfile,
            customCommand: "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind codebuddy --client-name CodeBuddy --client-originator CodeBuddy",
            installing: true
        )
        let data = HookInstaller.updatedConfigurationData(
            existingData: ideData,
            profile: codeBuddyCLIProfile,
            customCommand: "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind codebuddy-cli --client-name 'CodeBuddy CLI' --client-origin cli --client-originator CodeBuddy",
            installing: true
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "dark")

        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["SessionEnd"])
        XCTAssertNotNil(hooks["PreCompact"])
        XCTAssertNotNil(hooks["PermissionRequest"])

        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let commands = preToolUse.compactMap { entry in
            ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        }
        XCTAssertTrue(commands.first?.contains("--client-kind codebuddy-cli") == true)
        XCTAssertTrue(commands.contains { $0.contains("--client-kind codebuddy") && !$0.contains("--client-kind codebuddy-cli") })
        XCTAssertTrue(commands.contains("/usr/bin/printf keep"))
        XCTAssertEqual(
            commands.filter { $0.contains("/.ping-island/bin/ping-island-bridge") }.count,
            2
        )
        let managedPreToolUseHook = try XCTUnwrap((preToolUse.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(managedPreToolUseHook["timeout"] as? Int, 86_400)

        let permissionRequest = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let managedPermissionRequestHook = try XCTUnwrap((permissionRequest.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertTrue((managedPermissionRequestHook["command"] as? String)?.contains("--client-kind codebuddy-cli") == true)
        XCTAssertEqual(managedPermissionRequestHook["timeout"] as? Int, 86_400)
    }
}
