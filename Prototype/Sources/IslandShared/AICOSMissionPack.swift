//
//  AICOSMissionPack.swift
//  IslandShared
//
//  Pure AI-COS clipboard-prompt generation for Prototype tests.
//  Keep shape aligned with PingIsland AICOSMissionPackBuilder.
//

import Foundation

public enum SharedAICOSExecutionLevel: String, CaseIterable, Sendable {
    case l1, l2, l3

    public var displayName: String { rawValue.uppercased() }

    public func title(languageCode: String = "en") -> String {
        if languageCode.lowercased().hasPrefix("zh") {
            switch self {
            case .l1: return "L1 — 清晰、低风险、可立即验证"
            case .l2: return "L2 — 分阶段流程 + 简要目标"
            case .l3: return "L3 — Goal Contract + 持久 State"
            }
        }
        switch self {
        case .l1: return "L1 — Clear, low-risk, immediately verifiable"
        case .l2: return "L2 — Staged workflow with brief goal"
        case .l3: return "L3 — Goal Contract + durable State"
        }
    }

    public func protocolSummary(languageCode: String = "en") -> String {
        if languageCode.lowercased().hasPrefix("zh") {
            switch self {
            case .l1:
                return "根据请求与上下文推导一句预期结果，执行、验证并汇报。日常工作不要创建持久 State。"
            case .l2:
                return "陈述 Brief Goal，以及每个关键阶段带验证的短有序工作流。在范围内执行，验证整体结果并汇报。除非升级，不要使用 L3 状态机。"
            case .l3:
                return "建立 Goal Contract 与最小 State（状态、范围、成功标准、下一步、验证）。遵循显式转换。仅在工作跨会话或 Agent 边界时创建 Handoff。"
            }
        }
        switch self {
        case .l1:
            return "Derive a one-sentence expected result, execute, verify, and report."
        case .l2:
            return "State a Brief Goal and short workflow, execute stage by stage, verify, and report."
        case .l3:
            return "Establish a Goal Contract and minimal State; verify before completion."
        }
    }
}

public struct SharedAICOSSkillRef: Sendable {
    public var id: String
    public var title: String
    public var relativePath: String

    public init(id: String, title: String, relativePath: String) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
    }
}

public struct SharedAICOSMissionDraft: Sendable {
    public var missionID: String
    public var level: SharedAICOSExecutionLevel
    public var selectedSkills: [SharedAICOSSkillRef]
    public var protocolRootPath: String

    public init(
        missionID: String,
        level: SharedAICOSExecutionLevel,
        selectedSkills: [SharedAICOSSkillRef],
        protocolRootPath: String
    ) {
        self.missionID = missionID
        self.level = level
        self.selectedSkills = selectedSkills
        self.protocolRootPath = protocolRootPath
    }
}

public enum SharedAICOSMissionPackBuilder {
    public static func build(
        draft: SharedAICOSMissionDraft,
        languageCode: String = "en"
    ) -> (clipboardPrompt: String, readingPaths: [String]) {
        let readingPaths = draft.selectedSkills.map { skill in
            URL(fileURLWithPath: draft.protocolRootPath, isDirectory: true)
                .appendingPathComponent(skill.relativePath)
                .path
        }
        let chinese = languageCode.lowercased().hasPrefix("zh")
        let readingListPlain: String
        if readingPaths.isEmpty {
            readingListPlain = chinese ? "（未配置）" : "(none configured)"
        } else {
            readingListPlain = readingPaths.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }

        let levelName = draft.level.displayName
        let title = draft.level.title(languageCode: languageCode)
        let summary = draft.level.protocolSummary(languageCode: languageCode)

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

        return (clipboardPrompt, readingPaths)
    }
}
