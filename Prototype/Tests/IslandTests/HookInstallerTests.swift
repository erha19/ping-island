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

    let permissionRequest = try #require(hooks["PermissionRequest"] as? [[String: Any]])
    let installedHook = try #require(permissionRequest.last?["hooks"] as? [[String: Any]])
    #expect(installedHook.first?["timeout"] as? Int == 86_400)
    #expect(hooks["SessionEnd"] != nil)
    #expect(hooks["PreCompact"] != nil)
}

@Test
func installerReplacesLegacyIslandHooksButKeepsUnrelatedHooks() throws {
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
            "hooks": [{"type": "command", "command": "/Users/test/.island/bin/island-bridge --source claude"}],
            "matcher": "*"
          },
          {
            "hooks": [{"type": "command", "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source claude"}],
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
            "hooks": [{"type": "command", "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source codex"}],
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
            "hooks": [{"type": "command", "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source claude"}],
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
            "hooks": [{"type": "command", "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source claude"}],
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

    let installer = HookInstaller(homeDirectory: root)
    try installer.installClaudeAssets()
    try installer.installCodexAssets()
    try installer.installQoderAssets()
    try installer.installQoderWorkAssets()

    let claudeData = try Data(contentsOf: claudeSettingsURL)
    let claudeJSON = try #require(JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
    let claudeHooks = try #require(claudeJSON["hooks"] as? [String: Any])
    let preToolUse = try #require(claudeHooks["PreToolUse"] as? [[String: Any]])
    let preToolUseCommands = preToolUse.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(preToolUseCommands.contains("/usr/bin/true"))
    #expect(preToolUseCommands.contains { $0.contains("/.island/bin/island-bridge --source claude") })
    #expect(!preToolUseCommands.contains { $0.contains("/.vibe-island/bin/vibe-island-bridge") })
    #expect(preToolUseCommands.filter { $0.contains("/.island/bin/island-bridge --source claude") }.count == 1)

    let codexData = try Data(contentsOf: codexHooksURL)
    let codexJSON = try #require(JSONSerialization.jsonObject(with: codexData) as? [String: Any])
    let codexHooks = try #require(codexJSON["hooks"] as? [String: Any])
    let userPromptSubmit = try #require(codexHooks["UserPromptSubmit"] as? [[String: Any]])
    let codexCommands = userPromptSubmit.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(codexCommands.contains("/usr/bin/printf keep"))
    #expect(codexCommands.contains { $0.contains("/.island/bin/island-bridge --source codex") })
    #expect(!codexCommands.contains { $0.contains("/.vibe-island/bin/vibe-island-bridge") })
    #expect(codexCommands.filter { $0.contains("/.island/bin/island-bridge --source codex") }.count == 1)

    let qoderData = try Data(contentsOf: qoderSettingsURL)
    let qoderJSON = try #require(JSONSerialization.jsonObject(with: qoderData) as? [String: Any])
    let qoderHooks = try #require(qoderJSON["hooks"] as? [String: Any])
    let postToolUseFailure = try #require(qoderHooks["PostToolUseFailure"] as? [[String: Any]])
    let qoderCommands = postToolUseFailure.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(qoderCommands.contains("/usr/bin/printf qoder-keep"))
    #expect(qoderCommands.contains { $0.contains("/.island/bin/island-bridge --source claude --client-kind qoder --client-name Qoder") })
    #expect(!qoderCommands.contains { $0.contains("/.vibe-island/bin/vibe-island-bridge") })
    #expect(qoderCommands.filter { $0.contains("/.island/bin/island-bridge --source claude --client-kind qoder --client-name Qoder") }.count == 1)
    #expect(qoderHooks["UserPromptSubmit"] != nil)
    #expect(qoderHooks["PermissionRequest"] != nil)
    #expect(qoderHooks["Notification"] != nil)
    #expect(qoderHooks["Stop"] != nil)

    let qoderWorkData = try Data(contentsOf: qoderWorkSettingsURL)
    let qoderWorkJSON = try #require(JSONSerialization.jsonObject(with: qoderWorkData) as? [String: Any])
    let qoderWorkHooks = try #require(qoderWorkJSON["hooks"] as? [String: Any])
    let qoderWorkPostToolUseFailure = try #require(qoderWorkHooks["PostToolUseFailure"] as? [[String: Any]])
    let qoderWorkCommands = qoderWorkPostToolUseFailure.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(qoderWorkCommands.contains("/usr/bin/printf qoderwork-keep"))
    #expect(qoderWorkCommands.contains { $0.contains("/.island/bin/island-bridge --source claude --client-kind qoderwork --client-name QoderWork") })
    #expect(!qoderWorkCommands.contains { $0.contains("/.vibe-island/bin/vibe-island-bridge") })
    #expect(qoderWorkCommands.filter { $0.contains("/.island/bin/island-bridge --source claude --client-kind qoderwork --client-name QoderWork") }.count == 1)
    #expect(qoderWorkHooks["UserPromptSubmit"] != nil)
    #expect(qoderWorkHooks["PermissionRequest"] != nil)
    #expect(qoderWorkHooks["Notification"] != nil)
    #expect(qoderWorkHooks["Stop"] != nil)
    let qoderWorkPreToolUse = try #require(qoderWorkHooks["PreToolUse"] as? [[String: Any]])
    let qoderWorkManagedPreToolUse = try #require(
        qoderWorkPreToolUse.first {
            (((($0["hooks"] as? [[String: Any]])?.first)?["command"] as? String) ?? "")
                .contains("/.island/bin/island-bridge --source claude --client-kind qoderwork --client-name QoderWork")
        }
    )
    let qoderWorkManagedPreToolUseHook = try #require((qoderWorkManagedPreToolUse["hooks"] as? [[String: Any]])?.first)
    #expect(qoderWorkManagedPreToolUseHook["timeout"] as? Int == 86_400)
}

@Test
func installerAddsCodeBuddyAndCursorHooks() throws {
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

    let cursorSettingsDirectory = root.appending(path: "Library/Application Support/Cursor/User", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: cursorSettingsDirectory, withIntermediateDirectories: true)
    let cursorURL = cursorSettingsDirectory.appending(path: "settings.json")

    let installer = HookInstaller(homeDirectory: root)
    try installer.installCodeBuddyAssets()
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
        $0.contains("/.island/bin/island-bridge --source claude --client-kind codebuddy --client-name CodeBuddy --client-originator CodeBuddy")
    })
    #expect(codeBuddyHooks["SessionEnd"] != nil)
    #expect(codeBuddyHooks["PreCompact"] != nil)
    #expect(codeBuddyHooks["PermissionRequest"] == nil)
    #expect(codeBuddyHooks["Notification"] != nil)
    #expect(codeBuddyHooks["SubagentStop"] != nil)

    let cursorData = try Data(contentsOf: cursorURL)
    let cursorJSON = try #require(JSONSerialization.jsonObject(with: cursorData) as? [String: Any])
    let cursorHooks = try #require(cursorJSON["hooks"] as? [String: Any])
    let cursorUserPromptSubmit = try #require(cursorHooks["UserPromptSubmit"] as? [[String: Any]])
    let cursorCommands = cursorUserPromptSubmit.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(cursorCommands.contains {
        $0.contains("/.island/bin/island-bridge --source claude --client-kind cursor --client-name Cursor --client-originator Cursor")
    })
    #expect(cursorHooks["PermissionRequest"] != nil)
    #expect(cursorHooks["PreCompact"] != nil)
}
