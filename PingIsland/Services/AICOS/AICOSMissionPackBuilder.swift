//
//  AICOSMissionPackBuilder.swift
//  PingIsland
//
//  Builds a paste-ready Codex prompt for the selected AI-COS protocol level.
//

import AppKit
import Foundation

enum AICOSMissionPackBuilder {
    static func build(
        draft: AICOSMissionDraft,
        languageCode: String = "en",
        catalogSkills: [AICOSSkillRef] = AICOSProtocolCatalog.allSkills
    ) -> AICOSMissionPack {
        let protocolRoot = URL(fileURLWithPath: draft.protocolRootPath, isDirectory: true)
        let selected = draft.selectedSkillIDs.compactMap { id in
            catalogSkills.first { $0.id == id }
        }
        let readingPaths = selected.map { skill in
            skill.resolvedPath(protocolRoot: protocolRoot).path
        }

        let chinese = AICOSExecutionLevel.usesChinese(languageCode)
        let readingListPlain: String
        if readingPaths.isEmpty {
            readingListPlain = chinese ? "（未配置）" : "(none configured)"
        } else {
            readingListPlain = readingPaths.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }

        let levelName = draft.level.displayName
        let title = draft.level.title(languageCode: languageCode)
        let summary = draft.level.protocolSummary(languageCode: languageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let clipboardPrompt: String
        if chinese {
            clipboardPrompt = """
            请遵循 AI-COS \(levelName)。

            协议：\(title)
            摘要：\(summary)

            开始前请阅读：

            \(readingListPlain)

            然后仅按 AI-COS \(levelName) 规则执行用户请求。仅在存在阻碍安全执行的实质歧义时提问。最终结果需附带验证证据。
            """
        } else {
            clipboardPrompt = """
            Follow AI-COS \(levelName).

            Protocol: \(title)
            Summary: \(summary)

            Before you begin, read:

            \(readingListPlain)

            Then execute the user's request under AI-COS \(levelName) rules only. Ask only when a material ambiguity blocks safe execution. Report verification evidence with the final result.
            """
        }

        return AICOSMissionPack(
            clipboardPrompt: clipboardPrompt,
            requiredReadingPaths: readingPaths
        )
    }

    @MainActor
    static func copyPromptToClipboard(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
}
