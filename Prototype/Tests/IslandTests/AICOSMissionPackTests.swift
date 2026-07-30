import Testing
@testable import IslandShared

@Test
func sharedAICOSMissionPackMatchesExpectedShape() {
    let draft = SharedAICOSMissionDraft(
        missionID: "mission-shared-001",
        level: .l2,
        selectedSkills: [
            SharedAICOSSkillRef(id: "readme", title: "README", relativePath: "README.md"),
            SharedAICOSSkillRef(id: "protocol", title: "Protocol", relativePath: "PROTOCOL.md")
        ],
        protocolRootPath: "/tmp/ai-cos-protocol"
    )

    let english = SharedAICOSMissionPackBuilder.build(draft: draft, languageCode: "en")
    #expect(english.clipboardPrompt.contains("Follow AI-COS L2."))
    #expect(english.clipboardPrompt.contains("Protocol: L2 — Staged workflow with brief goal"))
    #expect(english.clipboardPrompt.contains("1. /tmp/ai-cos-protocol/README.md"))
    #expect(english.clipboardPrompt.contains("2. /tmp/ai-cos-protocol/PROTOCOL.md"))
    #expect(!english.clipboardPrompt.contains("Goal:"))
    #expect(!english.clipboardPrompt.contains("AI_COS_MISSION.md"))
    #expect(english.readingPaths.count == 2)

    let chinese = SharedAICOSMissionPackBuilder.build(draft: draft, languageCode: "zh-Hans")
    #expect(chinese.clipboardPrompt.contains("请遵循 AI-COS L2。"))
    #expect(chinese.clipboardPrompt.contains("协议：L2 — 分阶段流程 + 简要目标"))
    #expect(chinese.clipboardPrompt.contains("开始前请阅读："))
}

@Test
func sharedAICOSInvestmentDecisionPackIncludesDecisionSkillPaths() {
    let draft = SharedAICOSMissionDraft(
        missionID: "mission-invest-shared",
        level: .l3,
        selectedSkills: [
            SharedAICOSSkillRef(id: "readme", title: "README", relativePath: "README.md"),
            SharedAICOSSkillRef(id: "protocol", title: "Protocol", relativePath: "PROTOCOL.md"),
            SharedAICOSSkillRef(id: "schema-goal", title: "Goal", relativePath: "schemas/goal.md")
        ],
        protocolRootPath: "/tmp/ai-cos-protocol"
    )

    let pack = SharedAICOSMissionPackBuilder.buildInvestmentDecision(
        draft: draft,
        decisionSkillRootPath: "/tmp/decision-skill",
        languageCode: "en"
    )
    #expect(pack.clipboardPrompt.contains("Follow AI-COS L3."))
    #expect(pack.clipboardPrompt.contains("Investment Decision"))
    #expect(pack.readingPaths == [
        "/tmp/ai-cos-protocol/PROTOCOL.md",
        "/tmp/decision-skill/SKILL.md",
        "/tmp/decision-skill/references/investment-adapter.md"
    ])
    #expect(!pack.clipboardPrompt.contains("Summary:"))
    #expect(!pack.clipboardPrompt.contains("README.md"))
    #expect(pack.clipboardPrompt.contains("must be confirmed by the user"))
    #expect(pack.clipboardPrompt.contains("Do not place orders"))
}
