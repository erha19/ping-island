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
