//
//  AICOSMissionModels.swift
//  PingIsland
//
//  Domain models for AI-COS Mission Pack orchestration.
//

import Foundation

enum AICOSExecutionLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case l1
    case l2
    case l3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .l1: return "L1"
        case .l2: return "L2"
        case .l3: return "L3"
        }
    }

    /// English title kept for callers that do not pass a language code.
    var title: String { title(languageCode: "en") }

    /// English summary kept for callers that do not pass a language code.
    var protocolSummary: String { protocolSummary(languageCode: "en") }

    func title(languageCode: String) -> String {
        if Self.usesChinese(languageCode) {
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

    func protocolSummary(languageCode: String) -> String {
        if Self.usesChinese(languageCode) {
            switch self {
            case .l1:
                return """
                根据请求与上下文推导一句预期结果，执行、验证并汇报。\
                日常工作不要创建持久 State。
                """
            case .l2:
                return """
                陈述 Brief Goal，以及每个关键阶段带验证的短有序工作流。\
                在范围内执行，验证整体结果并汇报。除非升级，不要使用 L3 状态机。
                """
            case .l3:
                return """
                建立 Goal Contract 与最小 State（状态、范围、成功标准、下一步、验证）。\
                遵循显式转换。仅在工作跨会话或 Agent 边界时创建 Handoff。
                """
            }
        }
        switch self {
        case .l1:
            return """
            Derive a one-sentence expected result from the request and context, \
            execute, verify, and report. Do not create durable State for routine work.
            """
        case .l2:
            return """
            State a Brief Goal and a short ordered workflow with verification for \
            each meaningful stage. Execute within scope, verify the integrated result, \
            and report. Do not use the L3 state machine unless upgrading.
            """
        case .l3:
            return """
            Establish a Goal Contract and minimal State (status, scope, success criteria, \
            next action, verification). Follow explicit transitions. Create a Handoff only \
            when work crosses a session or Agent boundary.
            """
        }
    }

    static func usesChinese(_ languageCode: String) -> Bool {
        languageCode.lowercased().hasPrefix("zh")
    }
}

struct AICOSSkillRef: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    /// Path relative to the configured AI-COS protocol root.
    var relativePath: String
    var levels: Set<AICOSExecutionLevel>

    func resolvedPath(protocolRoot: URL) -> URL {
        protocolRoot.appendingPathComponent(relativePath)
    }
}

struct AICOSMissionDraft: Codable, Sendable {
    var missionID: String
    var level: AICOSExecutionLevel
    var selectedSkillIDs: [String]
    var protocolRootPath: String
    var createdAt: Date

    /// Legacy fields retained for decoding older history payloads.
    var goal: String
    var task: String
    var workspacePath: String

    var id: String { missionID }

    init(
        missionID: String = UUID().uuidString,
        level: AICOSExecutionLevel,
        selectedSkillIDs: [String],
        protocolRootPath: String,
        createdAt: Date = Date(),
        goal: String = "",
        task: String = "",
        workspacePath: String = ""
    ) {
        self.missionID = missionID
        self.level = level
        self.selectedSkillIDs = selectedSkillIDs
        self.protocolRootPath = protocolRootPath
        self.createdAt = createdAt
        self.goal = goal
        self.task = task
        self.workspacePath = workspacePath
    }
}

struct AICOSMissionPack: Sendable {
    var clipboardPrompt: String
    var requiredReadingPaths: [String]
}

enum AICOSMissionConstants {
    static let protocolRootDefaultsKey = "AICOS.protocolRootPath.v1"
    static let recentMissionDefaultsKey = "AICOS.recentMission.v1"
    static let launchTargetProfileIDDefaultsKey = "AICOS.launchTargetProfileID.v1"
    static let decisionSkillRootDefaultsKey = "AICOS.decisionSkillRootPath.v1"

    /// Default checkout used when present on this machine.
    static var defaultProtocolRootPath: String {
        NSHomeDirectory() + "/wiki/claude-obsidian/.worktrees/ai-cos-execution-protocol/ai-cos"
    }

    /// Default decision skill root (investment adapter lives under references/).
    static var defaultDecisionSkillRootPath: String {
        NSHomeDirectory() + "/wiki/claude-obsidian/skills/decision"
    }
}
