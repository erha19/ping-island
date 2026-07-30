//
//  SkillAgentSkillsPath.swift
//  PingIsland
//
//  Maps managed hook profiles / well-known homes to agent skills directories.
//

import Foundation

enum SkillAgentSkillsPath {
    /// Inferred skills directory for a managed Integration profile.
    nonisolated static func skillsDirectory(
        for profile: ManagedHookClientProfile,
        homeDirectory: URL = UserHomeDirectoryResolver.hookConfigurationHomeDirectory
    ) -> URL {
        let configURL = profile.primaryConfigurationURL(homeDirectory: homeDirectory)
        return configURL
            .deletingLastPathComponent()
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Built-in auto-discovery roots (relative to home). Existing directories only.
    nonisolated static func defaultAutoRootRelativePaths() -> [String] {
        [
            ".claude/skills",
            ".codex/skills",
            ".agents/skills",
            ".cursor/skills",
            ".gemini/skills",
            ".qwen/skills",
            ".kimi/skills",
            ".hermes/skills",
            ".pi/agent/skills",
        ]
    }
}
