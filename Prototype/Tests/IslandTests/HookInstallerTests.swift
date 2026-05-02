import Foundation
@testable import IslandApp
import Testing

@Test
func installerMergesClaudeHooksWithoutDroppingExistingValues() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let settingsURL = root.appending(path: ".claude/settings.json")
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
    {
      "env": {"EXISTING_VAR": "1"},
      "hooks": {
        "SessionStart": [{
          "hooks": [{"type": "command", "command": "/usr/bin/true"}],
          "matcher": "*"
        }]
      }
    }
    """
    try Data(existing.utf8).write(to: settingsURL)

    let installer = HookInstaller(homeDirectory: root)
    try installer.installClaudeAssets()

    let data = try Data(contentsOf: settingsURL)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let env = try #require(json["env"] as? [String: Any])
    #expect(env["EXISTING_VAR"] as? String == "1")
    #expect(env["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] as? String == "1")

    let hooks = try #require(json["hooks"] as? [String: Any])
    let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
    #expect(sessionStart.count >= 2)
    let sessionStartCommands = sessionStart.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(sessionStartCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source claude") })

    let permissionRequest = try #require(hooks["PermissionRequest"] as? [[String: Any]])
    let installedHook = try #require(permissionRequest.last?["hooks"] as? [[String: Any]])
    #expect(installedHook.first?["timeout"] as? Int == 86_400)
    #expect(hooks["SessionEnd"] != nil)
    #expect(hooks["PreCompact"] != nil)
}

@Test
func installerCreatesLauncherUnderPingIslandSupportDirectory() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installer = HookInstaller(homeDirectory: root)
    try installer.installCodexAssets()

    let launcherURL = root.appending(path: ".ping-island/bin/ping-island-bridge")
    #expect(FileManager.default.fileExists(atPath: launcherURL.path()))

    let launcher = try String(contentsOf: launcherURL, encoding: .utf8)
    #expect(launcher.contains("PingIslandBridge"))
    #expect(launcher.contains("IslandBridge"))
}

@Test
func installerDeduplicatesManagedHooksButKeepsUnrelatedHooks() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let claudeSettingsURL = root.appending(path: ".claude/settings.json")
    try FileManager.default.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let claudeExisting = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source claude"}],
            "matcher": "*"
          },
          {
            "hooks": [{"type": "command", "command": "/usr/bin/true"}],
            "matcher": "*"
          }
        ]
      }
    }
    """
    try Data(claudeExisting.utf8).write(to: claudeSettingsURL)

    let codexHooksURL = root.appending(path: ".codex/hooks.json")
    try FileManager.default.createDirectory(at: codexHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let codexExisting = """
    {
      "hooks": {
        "UserPromptSubmit": [
          {
            "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source codex"}],
            "matcher": "*"
          },
          {
            "hooks": [{"type": "command", "command": "/usr/bin/printf keep"}],
            "matcher": "*"
          }
        ]
      }
    }
    """
    try Data(codexExisting.utf8).write(to: codexHooksURL)

    let qoderSettingsURL = root.appending(path: ".qoder/settings.json")
    try FileManager.default.createDirectory(at: qoderSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let qoderExisting = """
    {
      "hooks": {
        "PostToolUseFailure": [
          {
            "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder --client-name Qoder --client-originator Qoder"}],
            "matcher": "*"
          },
          {
            "hooks": [{"type": "command", "command": "/usr/bin/printf qoder-keep"}],
            "matcher": "*"
          }
        ]
      }
    }
    """
    try Data(qoderExisting.utf8).write(to: qoderSettingsURL)

    let qoderWorkSettingsURL = root.appending(path: ".qoderwork/settings.json")
    try FileManager.default.createDirectory(at: qoderWorkSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let qoderWorkExisting = """
    {
      "hooks": {
        "PostToolUseFailure": [
          {
            "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind qoderwork --client-name QoderWork --client-originator QoderWork"}],
            "matcher": "*"
          },
          {
            "hooks": [{"type": "command", "command": "/usr/bin/printf qoderwork-keep"}],
            "matcher": "*"
          }
        ]
      }
    }
    """
    try Data(qoderWorkExisting.utf8).write(to: qoderWorkSettingsURL)

    let workBuddySettingsURL = root.appending(path: ".workbuddy/settings.json")
    try FileManager.default.createDirectory(at: workBuddySettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let workBuddyExisting = """
    {
      "hooks": {
        "PostToolUse": [
          {
            "hooks": [{"type": "command", "command": "/Users/test/.ping-island/bin/ping-island-bridge --source claude --client-kind workbuddy --client-name WorkBuddy --client-originator WorkBuddy"}],
            "matcher": "*"
          },
          {
            "hooks": [{"type": "command", "command": "/usr/bin/printf workbuddy-keep"}],
            "matcher": "*"
          }
        ]
      }
    }
    """
    try Data(workBuddyExisting.utf8).write(to: workBuddySettingsURL)

    let installer = HookInstaller(homeDirectory: root)
    try installer.installClaudeAssets()
    try installer.installCodexAssets()
    try installer.installQoderAssets()
    try installer.installQoderCLIAssets()
    try installer.installQoderWorkAssets()
    try installer.installWorkBuddyAssets()

    let claudeData = try Data(contentsOf: claudeSettingsURL)
    let claudeJSON = try #require(JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
    let claudeHooks = try #require(claudeJSON["hooks"] as? [String: Any])
    let preToolUse = try #require(claudeHooks["PreToolUse"] as? [[String: Any]])
    let preToolUseCommands = preToolUse.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(preToolUseCommands.contains("/usr/bin/true"))
    #expect(preToolUseCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source claude") })
    #expect(preToolUseCommands.filter { $0.contains("/.ping-island/bin/ping-island-bridge --source claude") }.count == 1)

    let codexData = try Data(contentsOf: codexHooksURL)
    let codexJSON = try #require(JSONSerialization.jsonObject(with: codexData) as? [String: Any])
    let codexHooks = try #require(codexJSON["hooks"] as? [String: Any])
    let userPromptSubmit = try #require(codexHooks["UserPromptSubmit"] as? [[String: Any]])
    let codexCommands = userPromptSubmit.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(codexCommands.contains("/usr/bin/printf keep"))
    #expect(codexCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source codex") })
    #expect(codexCommands.filter { $0.contains("/.ping-island/bin/ping-island-bridge --source codex") }.count == 1)
    #expect(codexHooks["PreToolUse"] != nil)
    #expect(codexHooks["PostToolUse"] != nil)
    #expect(codexHooks["PermissionRequest"] != nil)
    #expect(codexHooks["Stop"] != nil)

    let qoderData = try Data(contentsOf: qoderSettingsURL)
    let qoderJSON = try #require(JSONSerialization.jsonObject(with: qoderData) as? [String: Any])
    let qoderHooks = try #require(qoderJSON["hooks"] as? [String: Any])
    let postToolUseFailure = try #require(qoderHooks["PostToolUseFailure"] as? [[String: Any]])
    let qoderPostToolUseFailureCommands = postToolUseFailure.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(qoderPostToolUseFailureCommands.contains("/usr/bin/printf qoder-keep"))
    #expect(qoderPostToolUseFailureCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder --client-name Qoder --client-originator Qoder") })
    #expect(qoderHooks["UserPromptSubmit"] != nil)
    #expect(qoderHooks["PermissionRequest"] != nil)
    #expect(qoderHooks["Notification"] != nil)
    #expect(qoderHooks["Stop"] != nil)
    #expect(qoderHooks["SubagentStop"] != nil)
    #expect(qoderHooks["SessionStart"] != nil)
    #expect(qoderHooks["SessionEnd"] != nil)
    #expect(qoderHooks["PreCompact"] != nil)
    let qoderPreToolUse = try #require(qoderHooks["PreToolUse"] as? [[String: Any]])
    let qoderCommands = qoderPreToolUse.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    let qoderIDECommand = "/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder --client-name Qoder --client-originator Qoder"
    let qoderCLICommand = "/.ping-island/bin/ping-island-bridge --source claude --client-kind qoder-cli --client-name 'Qoder CLI' --client-origin cli --client-originator Qoder"
    #expect(qoderCommands.first?.contains(qoderCLICommand) == true)
    #expect(qoderCommands.contains { $0.contains(qoderIDECommand) })
    #expect(qoderCommands.filter { $0.contains(qoderIDECommand) }.count == 1)
    #expect(qoderCommands.filter { $0.contains(qoderCLICommand) }.count == 1)
    let qoderManagedPreToolUse = try #require(qoderPreToolUse.first)
    let qoderManagedPreToolUseHook = try #require((qoderManagedPreToolUse["hooks"] as? [[String: Any]])?.first)
    #expect(qoderManagedPreToolUseHook["timeout"] as? Int == 86_400)

    let qoderWorkData = try Data(contentsOf: qoderWorkSettingsURL)
    let qoderWorkJSON = try #require(JSONSerialization.jsonObject(with: qoderWorkData) as? [String: Any])
    let qoderWorkHooks = try #require(qoderWorkJSON["hooks"] as? [String: Any])
    let qoderWorkPostToolUseFailure = try #require(qoderWorkHooks["PostToolUseFailure"] as? [[String: Any]])
    let qoderWorkCommands = qoderWorkPostToolUseFailure.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(qoderWorkCommands.contains("/usr/bin/printf qoderwork-keep"))
    #expect(qoderWorkCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind qoderwork --client-name QoderWork --client-originator QoderWork") })
    #expect(qoderWorkCommands.filter { $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind qoderwork --client-name QoderWork --client-originator QoderWork") }.count == 1)
    #expect(qoderWorkHooks["UserPromptSubmit"] != nil)
    #expect(qoderWorkHooks["PermissionRequest"] != nil)
    #expect(qoderWorkHooks["Notification"] != nil)
    #expect(qoderWorkHooks["Stop"] != nil)
    let qoderWorkPreToolUse = try #require(qoderWorkHooks["PreToolUse"] as? [[String: Any]])
    let qoderWorkManagedPreToolUse = try #require(
        qoderWorkPreToolUse.first {
            (((($0["hooks"] as? [[String: Any]])?.first)?["command"] as? String) ?? "")
                .contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind qoderwork --client-name QoderWork --client-originator QoderWork")
        }
    )
    let qoderWorkManagedPreToolUseHook = try #require((qoderWorkManagedPreToolUse["hooks"] as? [[String: Any]])?.first)
    #expect(qoderWorkManagedPreToolUseHook["timeout"] == nil)

    let workBuddyData = try Data(contentsOf: workBuddySettingsURL)
    let workBuddyJSON = try #require(JSONSerialization.jsonObject(with: workBuddyData) as? [String: Any])
    let workBuddyHooks = try #require(workBuddyJSON["hooks"] as? [String: Any])
    let workBuddyPostToolUse = try #require(workBuddyHooks["PostToolUse"] as? [[String: Any]])
    let workBuddyCommands = workBuddyPostToolUse.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(workBuddyCommands.contains("/usr/bin/printf workbuddy-keep"))
    #expect(workBuddyCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind workbuddy --client-name WorkBuddy --client-originator WorkBuddy") })
    #expect(workBuddyCommands.filter { $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind workbuddy --client-name WorkBuddy --client-originator WorkBuddy") }.count == 1)
    #expect(workBuddyHooks["SessionEnd"] != nil)
    #expect(workBuddyHooks["PreCompact"] != nil)
    #expect(workBuddyHooks["Notification"] != nil)
    #expect(workBuddyHooks["SubagentStop"] != nil)
    #expect(workBuddyHooks["PermissionRequest"] == nil)
}

@Test
func installerAddsCodeBuddyWorkBuddyAndCursorHooks() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let codeBuddyURL = root.appending(path: ".codebuddy/settings.json")
    try FileManager.default.createDirectory(at: codeBuddyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let codeBuddyExisting = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "hooks": [{"type": "command", "command": "/usr/bin/printf keep-codebuddy"}],
            "matcher": "*"
          }
        ]
      }
    }
    """
    try Data(codeBuddyExisting.utf8).write(to: codeBuddyURL)

    let workBuddyURL = root.appending(path: ".workbuddy/settings.json")
    try FileManager.default.createDirectory(at: workBuddyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let workBuddyExisting = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "hooks": [{"type": "command", "command": "/usr/bin/printf keep-workbuddy"}],
            "matcher": "*"
          }
        ]
      }
    }
    """
    try Data(workBuddyExisting.utf8).write(to: workBuddyURL)

    let cursorSettingsDirectory = root.appending(path: "Library/Application Support/Cursor/User", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: cursorSettingsDirectory, withIntermediateDirectories: true)
    let cursorURL = cursorSettingsDirectory.appending(path: "settings.json")

    let installer = HookInstaller(homeDirectory: root)
    try installer.installCodeBuddyAssets()
    try installer.installWorkBuddyAssets()
    try installer.installCursorAssets()

    let codeBuddyData = try Data(contentsOf: codeBuddyURL)
    let codeBuddyJSON = try #require(JSONSerialization.jsonObject(with: codeBuddyData) as? [String: Any])
    let codeBuddyHooks = try #require(codeBuddyJSON["hooks"] as? [String: Any])
    let codeBuddyPreToolUse = try #require(codeBuddyHooks["PreToolUse"] as? [[String: Any]])
    let codeBuddyCommands = codeBuddyPreToolUse.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(codeBuddyCommands.contains("/usr/bin/printf keep-codebuddy"))
    #expect(codeBuddyCommands.contains {
        $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind codebuddy --client-name CodeBuddy --client-originator CodeBuddy")
    })
    #expect(codeBuddyHooks["SessionEnd"] != nil)
    #expect(codeBuddyHooks["PreCompact"] != nil)
    #expect(codeBuddyHooks["PermissionRequest"] == nil)
    #expect(codeBuddyHooks["Notification"] != nil)
    #expect(codeBuddyHooks["SubagentStop"] != nil)

    let workBuddyData = try Data(contentsOf: workBuddyURL)
    let workBuddyJSON = try #require(JSONSerialization.jsonObject(with: workBuddyData) as? [String: Any])
    let workBuddyHooks = try #require(workBuddyJSON["hooks"] as? [String: Any])
    let workBuddyPreToolUse = try #require(workBuddyHooks["PreToolUse"] as? [[String: Any]])
    let workBuddyCommands = workBuddyPreToolUse.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(workBuddyCommands.contains("/usr/bin/printf keep-workbuddy"))
    #expect(workBuddyCommands.contains {
        $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind workbuddy --client-name WorkBuddy --client-originator WorkBuddy")
    })
    #expect(workBuddyHooks["SessionEnd"] != nil)
    #expect(workBuddyHooks["PreCompact"] != nil)
    #expect(workBuddyHooks["PermissionRequest"] == nil)
    #expect(workBuddyHooks["Notification"] != nil)
    #expect(workBuddyHooks["SubagentStop"] != nil)

    let cursorData = try Data(contentsOf: cursorURL)
    let cursorJSON = try #require(JSONSerialization.jsonObject(with: cursorData) as? [String: Any])
    let cursorHooks = try #require(cursorJSON["hooks"] as? [String: Any])
    let cursorUserPromptSubmit = try #require(cursorHooks["UserPromptSubmit"] as? [[String: Any]])
    let cursorCommands = cursorUserPromptSubmit.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(cursorCommands.contains {
        $0.contains("/.ping-island/bin/ping-island-bridge --source claude --client-kind cursor --client-name Cursor --client-originator Cursor")
    })
    #expect(cursorHooks["PermissionRequest"] != nil)
    #expect(cursorHooks["PreCompact"] != nil)
}

@Test
func installerAcceptsJSONCSettingsFiles() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let settingsURL = root.appending(path: ".claude/settings.json")
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
    {
      // user-defined environment should be preserved
      "env": {
        "EXISTING_VAR": "1",
      },
      "hooks": {
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/usr/bin/true",
              },
            ],
            "matcher": "*",
          },
        ],
      },
    }
    """
    try Data(existing.utf8).write(to: settingsURL)

    let installer = HookInstaller(homeDirectory: root)
    try installer.installClaudeAssets()

    let data = try Data(contentsOf: settingsURL)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let env = try #require(json["env"] as? [String: Any])
    #expect(env["EXISTING_VAR"] as? String == "1")

    let hooks = try #require(json["hooks"] as? [String: Any])
    let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
    let commands = sessionStart.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(commands.contains("/usr/bin/true"))
    #expect(commands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source claude") })
}

@Test
func installerAddsCopilotHooksUsingGitHubFormat() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let hooksURL = root.appending(path: ".github/hooks/island.json")
    try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
    {
      "version": 1,
      "hooks": {
        "sessionStart": [
          {
            "type": "command",
            "bash": "/usr/bin/printf keep-copilot"
          },
          {
            "type": "command",
            "bash": "/Users/test/.ping-island/bin/ping-island-bridge --source copilot --event sessionStart"
          }
        ]
      }
    }
    """
    try Data(existing.utf8).write(to: hooksURL)

    let installer = HookInstaller(homeDirectory: root)
    try installer.installCopilotAssets()

    let data = try Data(contentsOf: hooksURL)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["version"] as? Int == 1)

    let hooks = try #require(json["hooks"] as? [String: Any])
    let sessionStart = try #require(hooks["sessionStart"] as? [[String: Any]])
    let sessionStartCommands = sessionStart.compactMap { $0["bash"] as? String }
    #expect(sessionStartCommands.contains("/usr/bin/printf keep-copilot"))
    #expect(sessionStartCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source copilot --event sessionStart") })
    #expect(!sessionStart.contains { $0["hooks"] != nil || $0["matcher"] != nil })

    let preToolUse = try #require(hooks["preToolUse"] as? [[String: Any]])
    let preToolUseCommands = preToolUse.compactMap { $0["bash"] as? String }
    #expect(preToolUseCommands.contains { $0.contains("/.ping-island/bin/ping-island-bridge --source copilot --event preToolUse") })
}
