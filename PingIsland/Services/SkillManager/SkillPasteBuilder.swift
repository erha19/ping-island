//
//  SkillPasteBuilder.swift
//  PingIsland
//
//  Builds a short paste-ready prompt that tells an agent which local skill to use.
//

import AppKit
import Foundation

enum SkillPasteBuilder {
    nonisolated static func buildPrompt(for skill: LocalSkill, languageCode: String) -> String {
        let usesChinese = languageCode.lowercased().hasPrefix("zh")
        let description = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesChinese {
            var lines = [
                "请使用以下本地技能执行我的请求：",
                "- 名称: \(skill.name)",
                "- 路径: \(skill.directoryPath)",
            ]
            if let description, !description.isEmpty {
                lines.append("- 说明: \(description)")
            }
            lines.append("")
            lines.append("请先阅读该路径下的 SKILL.md，再按技能要求执行。")
            return lines.joined(separator: "\n")
        }

        var lines = [
            "Please use the following local skill for my request:",
            "- Name: \(skill.name)",
            "- Path: \(skill.directoryPath)",
        ]
        if let description, !description.isEmpty {
            lines.append("- Description: \(description)")
        }
        lines.append("")
        lines.append("Read SKILL.md in that path first, then follow the skill.")
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func copyPromptToClipboard(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
}
