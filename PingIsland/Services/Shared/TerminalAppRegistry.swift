//
//  TerminalAppRegistry.swift
//  PingIsland
//
//  Centralized registry of known terminal applications
//

import Foundation

/// Registry of known terminal application names and bundle identifiers
struct TerminalAppRegistry: Sendable {
    private nonisolated static let terminalDisplayNamesByBundleIdentifier: [String: String] = [
        "com.apple.terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "com.openai.codex": "Codex",
        "com.mitchellh.ghostty": "Ghostty",
        "com.cmuxterm.app": "cmux",
        "io.alacritty": "Alacritty",
        "org.alacritty": "Alacritty",
        "net.kovidgoyal.kitty": "kitty",
        "co.zeit.hyper": "Hyper",
        "dev.warp.warp-stable": "Warp",
        "com.github.wez.wezterm": "WezTerm"
    ]

    private nonisolated static let terminalBundleIdentifiersByProgram: [String: String] = [
        "iterm2": "com.googlecode.iterm2",
        "iterm": "com.googlecode.iterm2",
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal",
        "terminal": "com.apple.Terminal",
        "terminal.app": "com.apple.Terminal",
        "ghostty": "com.mitchellh.ghostty",
        "cmux": "com.cmuxterm.app",
        "alacritty": "io.alacritty",
        "kitty": "net.kovidgoyal.kitty",
        "hyper": "co.zeit.hyper",
        "warp": "dev.warp.Warp-Stable",
        "warpterminal": "dev.warp.Warp-Stable",
        "wezterm": "com.github.wez.wezterm",
        "wezterm-gui": "com.github.wez.wezterm"
    ]

    nonisolated static let ideBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.trae.app",
        "com.codebuddy.app",
        "com.tencent.codebuddy",
        "com.workbuddy.workbuddy",
        "com.qoder.ide",
        "com.qoder.work"
    ]

    nonisolated static let helperBundleToHostBundle: [String: String] = [
        "com.microsoft.VSCode.helper": "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders.helper": "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92.helper": "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf.helper": "com.exafunction.windsurf",
        "dev.zed.Zed.helper": "dev.zed.Zed",
        "com.trae.app.helper": "com.trae.app",
        "com.codebuddy.app.helper": "com.codebuddy.app",
        "com.tencent.codebuddy.helper": "com.tencent.codebuddy",
        "com.workbuddy.workbuddy.helper": "com.workbuddy.workbuddy",
        "com.qoder.ide.helper": "com.qoder.ide",
        "com.qoder.work.helper": "com.qoder.work",
        "com.openai.codex.helper": "com.openai.codex"
    ]

    /// Terminal app names for process matching
    nonisolated static let appNames: Set<String> = [
        "Terminal",
        "iTerm2",
        "iTerm",
        "Codex",
        "Ghostty",
        "cmux",
        "Alacritty",
        "kitty",
        "Hyper",
        "Warp",
        "WezTerm",
        "Tabby",
        "Rio",
        "Contour",
        "foot",
        "st",
        "urxvt",
        "xterm",
        "Code",           // VS Code
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "Trae",
        "CodeBuddy",
        "WorkBuddy",
        "Qoder",
        "QoderWork",
        "zed"
    ]

    /// Bundle identifiers for terminal apps (for window enumeration)
    nonisolated static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.openai.codex",
        "com.mitchellh.ghostty",
        "com.cmuxterm.app",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "com.trae.app",
        "com.codebuddy.app",
        "com.tencent.codebuddy",
        "com.workbuddy.workbuddy",
        "com.qoder.ide",
        "com.qoder.work",
        "dev.zed.Zed"
    ]

    /// Check if an app name or command path is a known terminal
    nonisolated static func isTerminal(_ appNameOrCommand: String) -> Bool {
        let lower = appNameOrCommand.lowercased()

        // Check if any known app name is contained in the command (case-insensitive)
        for name in appNames {
            if lower.contains(name.lowercased()) {
                return true
            }
        }

        // Additional checks for common patterns
        return lower.contains("terminal") || lower.contains("iterm")
    }

    /// Check if a bundle identifier is a known terminal
    nonisolated static func isTerminalBundle(_ bundleId: String) -> Bool {
        bundleIdentifiers.contains(bundleId)
    }

    nonisolated static func inferredBundleIdentifier(forTerminalProgram program: String?) -> String? {
        let normalizedProgram = program?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedProgram, !normalizedProgram.isEmpty else {
            return nil
        }
        return terminalBundleIdentifiersByProgram[normalizedProgram]
    }

    nonisolated static func inferredBundleIdentifier(forCommand command: String?) -> String? {
        guard let normalizedCommand = command?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalizedCommand.isEmpty else {
            return nil
        }

        if normalizedCommand.contains("itermserver") || normalizedCommand.contains("iterm2") {
            return "com.googlecode.iterm2"
        }
        if normalizedCommand.contains("/terminal.app/")
            || normalizedCommand.hasSuffix("/terminal")
            || normalizedCommand.contains("apple_terminal") {
            return "com.apple.Terminal"
        }
        if normalizedCommand.contains("ghostty") {
            return "com.mitchellh.ghostty"
        }
        if normalizedCommand.contains("cmux") {
            return "com.cmuxterm.app"
        }
        if normalizedCommand.contains("wezterm") {
            return "com.github.wez.wezterm"
        }
        if normalizedCommand.contains("warp") {
            return "dev.warp.Warp-Stable"
        }
        if normalizedCommand.contains("alacritty") {
            return "io.alacritty"
        }
        if normalizedCommand.contains("kitty") {
            return "net.kovidgoyal.kitty"
        }
        if normalizedCommand.contains("hyper") {
            return "co.zeit.hyper"
        }

        return nil
    }

    nonisolated static func canonicalDisplayName(
        bundleIdentifier: String?,
        program: String?,
        fallbackName: String? = nil
    ) -> String? {
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedBundleIdentifier,
           let displayName = terminalDisplayNamesByBundleIdentifier[normalizedBundleIdentifier] {
            return displayName
        }

        if let inferredBundleIdentifier = inferredBundleIdentifier(forTerminalProgram: program)?
            .lowercased(),
           let displayName = terminalDisplayNamesByBundleIdentifier[inferredBundleIdentifier] {
            return displayName
        }

        guard let fallbackName = fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallbackName.isEmpty,
              isTerminal(fallbackName) else {
            return nil
        }
        return fallbackName
    }

    nonisolated static func isIDEBundle(_ bundleId: String) -> Bool {
        ideBundleIdentifiers.contains(normalizedHostBundleIdentifier(for: bundleId))
    }

    nonisolated static func normalizedHostBundleIdentifier(for bundleId: String) -> String {
        helperBundleToHostBundle[bundleId] ?? bundleId
    }
}
