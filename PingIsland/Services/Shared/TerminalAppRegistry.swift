//
//  TerminalAppRegistry.swift
//  PingIsland
//
//  Centralized registry of known terminal applications
//

import Foundation

/// Registry of known terminal application names and bundle identifiers
struct TerminalAppRegistry: Sendable {
    nonisolated static let ideBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.trae.app",
        "com.codebuddy.app",
        "com.tencent.codebuddy",
        "com.qoder.ide"
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
        "com.qoder.ide.helper": "com.qoder.ide",
        "com.openai.codex.helper": "com.openai.codex"
    ]

    /// Terminal app names for process matching
    nonisolated static let appNames: Set<String> = [
        "Terminal",
        "iTerm2",
        "iTerm",
        "Codex",
        "Ghostty",
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
        "Qoder",
        "zed"
    ]

    /// Bundle identifiers for terminal apps (for window enumeration)
    nonisolated static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.openai.codex",
        "com.mitchellh.ghostty",
        "io.alacritty",
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
        "com.qoder.ide",
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

    nonisolated static func isIDEBundle(_ bundleId: String) -> Bool {
        ideBundleIdentifiers.contains(normalizedHostBundleIdentifier(for: bundleId))
    }

    nonisolated static func normalizedHostBundleIdentifier(for bundleId: String) -> String {
        helperBundleToHostBundle[bundleId] ?? bundleId
    }
}
