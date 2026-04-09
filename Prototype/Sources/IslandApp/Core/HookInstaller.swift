import Foundation

private enum HookConfigParser {
    static func parseJSONObject(from data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let sanitized = removeTrailingCommas(from: stripJSONComments(from: string))
        guard let sanitizedData = sanitized.data(using: .utf8) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: sanitizedData) as? [String: Any]
    }

    private static func stripJSONComments(from string: String) -> String {
        var output = ""
        var index = string.startIndex
        var isInsideString = false
        var isEscaping = false
        var isLineComment = false
        var isBlockComment = false

        while index < string.endIndex {
            let character = string[index]
            let nextIndex = string.index(after: index)
            let nextCharacter = nextIndex < string.endIndex ? string[nextIndex] : nil

            if isLineComment {
                if character == "\n" {
                    isLineComment = false
                    output.append(character)
                }
                index = nextIndex
                continue
            }

            if isBlockComment {
                if character == "\n" {
                    output.append(character)
                } else if character == "*", nextCharacter == "/" {
                    isBlockComment = false
                    index = string.index(after: nextIndex)
                    continue
                }
                index = nextIndex
                continue
            }

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", nextCharacter == "/" {
                isLineComment = true
                index = string.index(after: nextIndex)
                continue
            }

            if character == "/", nextCharacter == "*" {
                isBlockComment = true
                index = string.index(after: nextIndex)
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return output
    }

    private static func removeTrailingCommas(from string: String) -> String {
        let characters = Array(string)
        var output = ""
        var index = 0
        var isInsideString = false
        var isEscaping = false

        while index < characters.count {
            let character = characters[index]

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                index += 1
                continue
            }

            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace {
                    lookahead += 1
                }

                if lookahead < characters.count, characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return output
    }
}

struct HookInstaller {
    private static let supportDirectoryName = ".ping-island"
    private static let bridgeLauncherName = "ping-island-bridge"
    private static let bridgeBinaryName = "PingIslandBridge"
    private static let legacyBridgeBinaryName = "IslandBridge"

    let homeDirectory: URL
    let appSupportDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        self.appSupportDirectory = homeDirectory.appending(path: Self.supportDirectoryName, directoryHint: .isDirectory)
    }

    func installClaudeAssets() throws {
        try ensureSupportFiles()
        let fileURL = homeDirectory.appending(path: ".claude/settings.json")
        let current = try readJSON(fileURL) ?? [:]
        var updated = current
        var hooks = current["hooks"] as? [String: Any] ?? [:]

        for event in [
            "SessionStart",
            "SessionEnd",
            "Stop",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Notification",
            "UserPromptSubmit",
            "PreCompact",
            "SubagentStart",
            "SubagentStop"
        ] {
            hooks[event] = installHookArray(
                existing: hooks[event],
                command: bridgeCommand(source: "claude"),
                timeout: event == "PermissionRequest" ? 86_400 : nil
            )
        }

        updated["hooks"] = hooks
        updated["env"] = mergedEnvironment(from: current["env"] as? [String: Any] ?? [:])
        updated["statusLine"] = [
            "type": "command",
            "command": statusLineCommand()
        ]

        try writeJSON(updated, to: fileURL)
    }

    func installCodexAssets() throws {
        try ensureSupportFiles()
        let fileURL = homeDirectory.appending(path: ".codex/hooks.json")
        let current = try readJSON(fileURL) ?? [:]
        var updated = current
        var hooks = current["hooks"] as? [String: Any] ?? [:]

        for event in [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop"
        ] {
            hooks[event] = installHookArray(existing: hooks[event], command: bridgeCommand(source: "codex"))
        }

        updated["hooks"] = hooks
        try writeJSON(updated, to: fileURL)
    }

    func installCopilotAssets() throws {
        try ensureSupportFiles()
        let fileURL = homeDirectory.appending(path: ".github/hooks/island.json")
        let current = try readJSON(fileURL) ?? [:]
        var updated = current
        updated["version"] = 1
        var hooks = current["hooks"] as? [String: Any] ?? [:]

        for event in [
            "sessionStart",
            "sessionEnd",
            "userPromptSubmitted",
            "preToolUse",
            "postToolUse",
            "agentStop",
            "subagentStop",
            "errorOccurred"
        ] {
            hooks[event] = installCopilotHookArray(
                existing: hooks[event],
                command: bridgeCommand(source: "copilot", extraArguments: ["--event", event])
            )
        }

        updated["hooks"] = hooks
        try writeJSON(updated, to: fileURL)
    }

    func installCodeBuddyAssets() throws {
        try ensureSupportFiles()
        let fileURL = homeDirectory.appending(path: ".codebuddy/settings.json")
        let current = try readJSON(fileURL) ?? [:]
        var updated = current
        var hooks = current["hooks"] as? [String: Any] ?? [:]

        let plainEvents = ["UserPromptSubmit", "Stop", "SubagentStop", "SessionStart", "SessionEnd"]
        let wildcardEvents = ["PreToolUse", "PostToolUse", "Notification"]
        let compactEvents = ["PreCompact": ["auto", "manual"]]
        let command = bridgeCommand(
            source: "claude",
            extraArguments: [
                "--client-kind", "codebuddy",
                "--client-name", "CodeBuddy",
                "--client-originator", "CodeBuddy"
            ]
        )

        for event in plainEvents {
            hooks[event] = installHookArray(existing: hooks[event], command: command, matcher: nil)
        }

        for event in wildcardEvents {
            hooks[event] = installHookArray(existing: hooks[event], command: command, matcher: "*")
        }

        for (event, matchers) in compactEvents {
            var entries = hooks[event] as? [[String: Any]]
            for matcher in matchers {
                entries = installHookArray(existing: entries, command: command, matcher: matcher)
            }
            hooks[event] = entries
        }

        updated["hooks"] = hooks
        try writeJSON(updated, to: fileURL)
    }

    func installCursorAssets() throws {
        try installClaudeCompatibleAssets(
            relativePath: "Library/Application Support/Cursor/User/settings.json",
            clientKind: "cursor",
            clientName: "Cursor",
            clientOriginator: "Cursor"
        )
    }

    func installQoderAssets() throws {
        try installQoderCompatibleAssets(
            relativePath: ".qoder/settings.json",
            clientKind: "qoder",
            clientName: "Qoder",
            preToolUseTimeout: nil
        )
    }

    func installQoderWorkAssets() throws {
        try installQoderCompatibleAssets(
            relativePath: ".qoderwork/settings.json",
            clientKind: "qoderwork",
            clientName: "QoderWork",
            preToolUseTimeout: 86_400
        )
    }

    private func installQoderCompatibleAssets(
        relativePath: String,
        clientKind: String,
        clientName: String,
        preToolUseTimeout: Int?
    ) throws {
        try ensureSupportFiles()
        let fileURL = homeDirectory.appending(path: relativePath)
        let current = try readJSON(fileURL) ?? [:]
        var updated = current
        var hooks = current["hooks"] as? [String: Any] ?? [:]

        let wildcardEvents = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification"]
        let command = bridgeCommand(
            source: "claude",
            extraArguments: [
                "--client-kind", clientKind,
                "--client-name", clientName,
                "--client-originator", clientName
            ]
        )
        for event in ["UserPromptSubmit", "Stop"] {
            hooks[event] = installHookArray(existing: hooks[event], command: command, matcher: nil)
        }
        for event in wildcardEvents {
            hooks[event] = installHookArray(
                existing: hooks[event],
                command: command,
                timeout: event == "PermissionRequest" ? 86_400 : (event == "PreToolUse" ? preToolUseTimeout : nil),
                matcher: "*"
            )
        }

        updated["hooks"] = hooks
        try writeJSON(updated, to: fileURL)
    }

    private func installClaudeCompatibleAssets(
        relativePath: String,
        clientKind: String,
        clientName: String,
        clientOriginator: String
    ) throws {
        try ensureSupportFiles()
        let fileURL = homeDirectory.appending(path: relativePath)
        let current = try readJSON(fileURL) ?? [:]
        var updated = current
        var hooks = current["hooks"] as? [String: Any] ?? [:]

        let plainEvents = ["UserPromptSubmit", "Stop", "SubagentStop", "SessionStart", "SessionEnd"]
        let wildcardEvents = ["PreToolUse", "PostToolUse", "PermissionRequest", "Notification"]
        let compactEvents = ["PreCompact": ["auto", "manual"]]
        let command = bridgeCommand(
            source: "claude",
            extraArguments: [
                "--client-kind", clientKind,
                "--client-name", clientName,
                "--client-originator", clientOriginator
            ]
        )

        for event in plainEvents {
            hooks[event] = installHookArray(
                existing: hooks[event],
                command: command,
                matcher: nil
            )
        }

        for event in wildcardEvents {
            hooks[event] = installHookArray(
                existing: hooks[event],
                command: command,
                timeout: event == "PermissionRequest" ? 86_400 : nil,
                matcher: "*"
            )
        }

        for (event, matchers) in compactEvents {
            var entries = hooks[event] as? [[String: Any]]
            for matcher in matchers {
                entries = installHookArray(
                    existing: entries,
                    command: command,
                    matcher: matcher
                )
            }
            hooks[event] = entries
        }

        updated["hooks"] = hooks
        try writeJSON(updated, to: fileURL)
    }

    func installStatusLineScript() throws {
        try ensureBinDirectory()
        let scriptURL = appSupportDirectory.appending(path: "bin/island-statusline")
        try writeExecutable(
            """
            #!/bin/bash
            input=$(cat)
            _rl=$(echo "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
            [ -n "$_rl" ] && echo "$_rl" > /tmp/island-rate-limits.json
            echo "$input" | jq -r 'if .model.display_name then "[\\(.model.display_name)] \\(.context_window.used_percentage // 0)% context" else empty end' 2>/dev/null
            """,
            to: scriptURL
        )
    }

    private func ensureSupportFiles() throws {
        try ensureBinDirectory()
        try installStatusLineScript()
        try installBridgeLauncher()
    }

    private func ensureBinDirectory() throws {
        try FileManager.default.createDirectory(at: appSupportDirectory.appending(path: "bin"), withIntermediateDirectories: true)
    }

    private func installBridgeLauncher() throws {
        let launcherURL = appSupportDirectory.appending(path: "bin/\(Self.bridgeLauncherName)")
        try writeExecutable(
            """
            #!/bin/zsh
            if [ -x "\(resolvedBridgeBinaryPath())" ]; then
              exec "\(resolvedBridgeBinaryPath())" "$@"
            fi
            if [ -x "\(legacyBridgeBinaryPath())" ]; then
              exec "\(legacyBridgeBinaryPath())" "$@"
            fi
            echo "\(Self.bridgeBinaryName) binary not found" >&2
            exit 127
            """,
            to: launcherURL
        )
    }

    private func resolvedBridgeBinaryPath() -> String {
        let executable = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appending(path: Self.bridgeBinaryName)
            .path()
        return executable ?? "/Users/wudanwu/Island/Prototype/.build/debug/\(Self.bridgeBinaryName)"
    }

    private func legacyBridgeBinaryPath() -> String {
        let executable = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appending(path: Self.legacyBridgeBinaryName)
            .path()
        return executable ?? "/Users/wudanwu/Island/Prototype/.build/debug/\(Self.legacyBridgeBinaryName)"
    }

    private func bridgeCommand(source: String, extraArguments: [String] = []) -> String {
        let base = "\(appSupportDirectory.appending(path: "bin/\(Self.bridgeLauncherName)").path()) --source \(source)"
        guard !extraArguments.isEmpty else { return base }
        return ([base] + extraArguments).joined(separator: " ")
    }

    private func statusLineCommand() -> String {
        appSupportDirectory.appending(path: "bin/island-statusline").path()
    }

    private func mergedEnvironment(from existing: [String: Any]) -> [String: Any] {
        var result = existing
        result["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = "1"
        return result
    }

    private func installHookArray(
        existing: Any?,
        command: String,
        timeout: Int? = nil,
        matcher: String? = "*"
    ) -> [[String: Any]] {
        var hooks = (existing as? [[String: Any]] ?? []).filter { hook in
            guard let hookCommands = hook["hooks"] as? [[String: Any]] else {
                return true
            }

            return !hookCommands.contains { entry in
                let existingCommand = entry["command"] as? String ?? ""
                return Self.isIslandManagedHookCommand(existingCommand)
            }
        }

        var commandBody: [String: Any] = [
            "type": "command",
            "command": command
        ]
        if let timeout {
            commandBody["timeout"] = timeout
        }
        var hookBody: [String: Any] = ["hooks": [commandBody]]
        if let matcher {
            hookBody["matcher"] = matcher
        }
        let existingCommands = hooks.compactMap { hook -> String? in
            ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        }
        if !existingCommands.contains(command) {
            hooks.append(hookBody)
            return hooks
        }

        hooks = hooks.map { hook in
            guard let hookCommands = hook["hooks"] as? [[String: Any]],
                  let first = hookCommands.first,
                  first["command"] as? String == command
            else {
                return hook
            }

            guard let timeout else {
                return hook
            }

            var updatedHook = hook
            var updatedCommands = hookCommands
            updatedCommands[0]["timeout"] = timeout
            updatedHook["hooks"] = updatedCommands
            return updatedHook
        }
        return hooks
    }

    private func installCopilotHookArray(
        existing: Any?,
        command: String,
        timeoutSec: Int? = nil
    ) -> [[String: Any]] {
        var hooks = (existing as? [[String: Any]] ?? []).filter { hook in
            guard let existingCommand = Self.hookCommandString(hook) else {
                return true
            }
            return !Self.isIslandManagedHookCommand(existingCommand)
        }

        var hookBody: [String: Any] = [
            "type": "command",
            "bash": command
        ]
        if let timeoutSec {
            hookBody["timeoutSec"] = timeoutSec
        }

        let existingCommands = hooks.compactMap(Self.hookCommandString(_:))
        if !existingCommands.contains(command) {
            hooks.append(hookBody)
            return hooks
        }

        hooks = hooks.map { hook in
            guard Self.hookCommandString(hook) == command else {
                return hook
            }

            guard let timeoutSec else {
                return hook
            }

            var updatedHook = hook
            updatedHook["timeoutSec"] = timeoutSec
            return updatedHook
        }
        return hooks
    }

    private static func isIslandManagedHookCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("/.ping-island/bin/ping-island-bridge")
            || normalized.contains("/.ping-island/bin/island-bridge")
            || normalized.contains("island-state.py")
    }

    private static func hookCommandString(_ entry: [String: Any]) -> String? {
        let candidates = [
            entry["command"] as? String,
            entry["bash"] as? String,
            entry["powershell"] as? String
        ]
        return candidates.compactMap { command in
            let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }.first
    }

    private func readJSON(_ fileURL: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: fileURL.path()) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return HookConfigParser.parseJSONObject(from: data)
    }

    private func writeJSON(_ object: [String: Any], to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: [.atomic])
    }

    private func writeExecutable(_ text: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path())
    }
}
