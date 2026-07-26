import XCTest
@testable import Ping_Island

final class AICOSMissionPackBuilderTests: XCTestCase {
    func testBuildClipboardPromptIncludesProtocolAndDefaultReadings() {
        let draft = AICOSMissionDraft(
            missionID: "mission-test-001",
            level: .l2,
            selectedSkillIDs: ["readme", "protocol", "example-l2"],
            protocolRootPath: "/tmp/ai-cos-protocol"
        )

        let pack = AICOSMissionPackBuilder.build(draft: draft, languageCode: "en")

        XCTAssertTrue(pack.clipboardPrompt.contains("Follow AI-COS L2."))
        XCTAssertTrue(pack.clipboardPrompt.contains("L2 — Staged workflow with brief goal"))
        XCTAssertTrue(pack.clipboardPrompt.contains("1. /tmp/ai-cos-protocol/README.md"))
        XCTAssertTrue(pack.clipboardPrompt.contains("2. /tmp/ai-cos-protocol/PROTOCOL.md"))
        XCTAssertTrue(pack.clipboardPrompt.contains("3. /tmp/ai-cos-protocol/examples/l2-standard-task.md"))
        XCTAssertFalse(pack.clipboardPrompt.contains("Goal:"))
        XCTAssertFalse(pack.clipboardPrompt.contains("AI_COS_MISSION.md"))
        XCTAssertEqual(pack.requiredReadingPaths.count, 3)
    }

    func testBuildClipboardPromptUsesChineseWhenRequested() {
        let draft = AICOSMissionDraft(
            missionID: "mission-test-zh",
            level: .l1,
            selectedSkillIDs: ["readme", "protocol"],
            protocolRootPath: "/tmp/ai-cos-protocol"
        )

        let pack = AICOSMissionPackBuilder.build(draft: draft, languageCode: "zh-Hans")

        XCTAssertTrue(pack.clipboardPrompt.contains("请遵循 AI-COS L1。"))
        XCTAssertTrue(pack.clipboardPrompt.contains("协议：L1 — 清晰、低风险、可立即验证"))
        XCTAssertTrue(pack.clipboardPrompt.contains("开始前请阅读："))
        XCTAssertTrue(pack.clipboardPrompt.contains("然后仅按 AI-COS L1 规则执行用户请求"))
    }

    func testBuildInvestmentDecisionPromptIncludesL3AndDecisionSkills() {
        let draft = AICOSMissionDraft(
            missionID: "mission-invest-001",
            level: .l3,
            selectedSkillIDs: AICOSProtocolCatalog.defaultSelectedSkillIDs(for: .l3),
            protocolRootPath: "/tmp/ai-cos-protocol"
        )
        let decisionRoot = "/tmp/decision-skill"

        let pack = AICOSMissionPackBuilder.buildInvestmentDecision(
            draft: draft,
            decisionSkillRootPath: decisionRoot,
            languageCode: "en"
        )

        XCTAssertTrue(pack.clipboardPrompt.contains("Follow AI-COS L3."))
        XCTAssertTrue(pack.clipboardPrompt.contains("Investment Decision"))
        XCTAssertTrue(pack.clipboardPrompt.contains("/tmp/ai-cos-protocol/PROTOCOL.md"))
        XCTAssertTrue(pack.clipboardPrompt.contains("\(decisionRoot)/SKILL.md"))
        XCTAssertTrue(pack.clipboardPrompt.contains("\(decisionRoot)/references/investment-adapter.md"))
        XCTAssertTrue(pack.clipboardPrompt.contains("must be confirmed by the user"))
        XCTAssertTrue(pack.clipboardPrompt.contains("Do not place orders"))
        XCTAssertTrue(pack.requiredReadingPaths.contains("\(decisionRoot)/SKILL.md"))
        XCTAssertTrue(pack.requiredReadingPaths.contains("\(decisionRoot)/references/investment-adapter.md"))
    }

    func testBuildInvestmentDecisionPromptUsesChineseWhenRequested() {
        let draft = AICOSMissionDraft(
            missionID: "mission-invest-zh",
            level: .l3,
            selectedSkillIDs: ["readme", "protocol"],
            protocolRootPath: "/tmp/ai-cos-protocol"
        )

        let pack = AICOSMissionPackBuilder.buildInvestmentDecision(
            draft: draft,
            decisionSkillRootPath: "/tmp/decision-skill",
            languageCode: "zh-Hans"
        )

        XCTAssertTrue(pack.clipboardPrompt.contains("请遵循 AI-COS L3。"))
        XCTAssertTrue(pack.clipboardPrompt.contains("投资决策"))
        XCTAssertTrue(pack.clipboardPrompt.contains("重大投资结论必须由用户确认"))
        XCTAssertTrue(pack.clipboardPrompt.contains("不得下单"))
        XCTAssertTrue(pack.clipboardPrompt.contains("/tmp/decision-skill/SKILL.md"))
        XCTAssertTrue(pack.clipboardPrompt.contains("/tmp/decision-skill/references/investment-adapter.md"))
    }

    func testDecisionSkillRootResolutionAndExistence() {
        let suiteName = "AICOSDecisionSkillCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("aicos-decision-\(UUID().uuidString)", isDirectory: true)
        let references = tempRoot.appendingPathComponent("references", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        try? fileManager.createDirectory(at: references, withIntermediateDirectories: true)
        XCTAssertFalse(
            AICOSDecisionSkillCatalog.decisionSkillExists(
                override: tempRoot.path,
                fileManager: fileManager,
                defaults: defaults
            )
        )

        fileManager.createFile(atPath: tempRoot.appendingPathComponent("SKILL.md").path, contents: Data("x".utf8))
        fileManager.createFile(
            atPath: references.appendingPathComponent("investment-adapter.md").path,
            contents: Data("y".utf8)
        )
        XCTAssertTrue(
            AICOSDecisionSkillCatalog.decisionSkillExists(
                override: tempRoot.path,
                fileManager: fileManager,
                defaults: defaults
            )
        )

        AICOSDecisionSkillCatalog.setDecisionSkillRootPath(tempRoot.path, defaults: defaults)
        XCTAssertEqual(
            AICOSDecisionSkillCatalog.resolvedDecisionSkillRoot(defaults: defaults).path,
            URL(fileURLWithPath: tempRoot.path, isDirectory: true).path
        )
    }

    func testProtocolTitlesSwitchByLanguage() {
        XCTAssertEqual(
            AICOSExecutionLevel.l2.title(languageCode: "en"),
            "L2 — Staged workflow with brief goal"
        )
        XCTAssertEqual(
            AICOSExecutionLevel.l2.title(languageCode: "zh-Hans"),
            "L2 — 分阶段流程 + 简要目标"
        )
    }

    func testDefaultSkillsForLevels() {
        XCTAssertEqual(
            Set(AICOSProtocolCatalog.defaultSelectedSkillIDs(for: .l1)),
            Set(["readme", "protocol", "example-l1"])
        )
        XCTAssertTrue(AICOSProtocolCatalog.defaultSelectedSkillIDs(for: .l3).contains("schema-goal"))
        XCTAssertFalse(AICOSProtocolCatalog.defaultSelectedSkillIDs(for: .l1).contains("schema-goal"))
    }

    func testPreferredSessionMatchesProfileBrandAndWorkspace() throws {
        let cursor = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "cursor-hooks"))
        let sessionA = SessionState(
            sessionId: "claude:cursor-a",
            cwd: "/tmp/project-a",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "cursor",
                name: "Cursor"
            ),
            sessionName: "Cursor A"
        )
        let sessionB = SessionState(
            sessionId: "claude:cursor-b",
            cwd: "/tmp/project-b",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "cursor",
                name: "Cursor"
            ),
            sessionName: "Cursor B"
        )
        XCTAssertEqual(sessionA.clientInfo.brand, cursor.brand)
        XCTAssertEqual(sessionB.clientInfo.brand, cursor.brand)

        let preferred = AICOSCodexActivator.preferredSession(
            profile: cursor,
            workspacePath: "/tmp/project-a",
            sessions: [sessionB, sessionA]
        )
        XCTAssertEqual(preferred?.sessionId, sessionA.sessionId)

        let preferredReversed = AICOSCodexActivator.preferredSession(
            profile: cursor,
            workspacePath: "/tmp/project-a",
            sessions: [sessionA, sessionB]
        )
        XCTAssertEqual(preferredReversed?.sessionId, sessionA.sessionId)
    }

    @MainActor
    func testActivateReturnsFalseWhenNoBrandMatchAndEmptyBundleIDs() async throws {
        let kimi = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "kimi-hooks"))
        XCTAssertTrue(kimi.localAppBundleIdentifiers.isEmpty)

        let codexOnly = SessionState(
            sessionId: "codex:thread-a",
            cwd: "/tmp/project-a",
            provider: .codex,
            sessionName: "Codex"
        )

        let activated = await AICOSCodexActivator.activate(
            profile: kimi,
            workspacePath: "/tmp/project-a",
            matchingSessions: [codexOnly]
        )
        XCTAssertFalse(activated)
    }

    func testPreferredSessionReturnsNilWhenNoBrandMatch() throws {
        let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
        let codexOnly = SessionState(
            sessionId: "codex:thread-a",
            cwd: "/tmp/project-a",
            provider: .codex,
            sessionName: "A"
        )
        let preferred = AICOSCodexActivator.preferredSession(
            profile: zcode,
            workspacePath: "/tmp/project-a",
            sessions: [codexOnly]
        )
        XCTAssertNil(preferred)
    }

    func testPreferredSessionReturnsNilWithoutWorkspace() throws {
        let cursor = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "cursor-hooks"))
        let brandedSession = SessionState(
            sessionId: "claude:cursor-a",
            cwd: "/tmp/project-a",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "cursor",
                name: "Cursor"
            ),
            sessionName: "Cursor A"
        )

        let preferred = AICOSCodexActivator.preferredSession(
            profile: cursor,
            workspacePath: "",
            sessions: [brandedSession]
        )
        XCTAssertNil(preferred)
    }

    func testMissionHistoryRoundTrip() {
        let suiteName = "AICOSMissionHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let draft = AICOSMissionDraft(
            missionID: "history-1",
            level: .l3,
            selectedSkillIDs: ["protocol"],
            protocolRootPath: "/tmp/ai-cos"
        )
        AICOSMissionHistoryStore.saveRecent(draft, defaults: defaults)
        let loaded = AICOSMissionHistoryStore.loadRecent(defaults: defaults)
        XCTAssertEqual(loaded?.missionID, "history-1")
        XCTAssertEqual(loaded?.level, .l3)
    }

    func testLaunchTargetResolvePrefersStoredWhenInstalled() throws {
        let codex = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "codex-hooks"))
        let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
        let installed = [codex, zcode]
        let resolved = AICOSLaunchTargetResolver.resolve(
            storedProfileID: "zcode-hooks",
            installed: installed
        )
        XCTAssertEqual(resolved?.id, "zcode-hooks")
    }

    func testLaunchTargetResolveFallsBackToCodexWhenStoredMissing() throws {
        let codex = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "codex-hooks"))
        let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
        let resolved = AICOSLaunchTargetResolver.resolve(
            storedProfileID: "gemini-hooks",
            installed: [zcode, codex]
        )
        XCTAssertEqual(resolved?.id, "codex-hooks")
    }

    func testLaunchTargetResolveFallsBackToFirstInstalledWithoutCodex() throws {
        let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
        let kimi = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "kimi-hooks"))
        let installed = [zcode, kimi]
        let resolved = AICOSLaunchTargetResolver.resolve(
            storedProfileID: nil,
            installed: installed
        )
        XCTAssertEqual(resolved?.id, "zcode-hooks")
    }

    func testLaunchTargetResolveReturnsNilWhenNothingInstalled() {
        let resolved = AICOSLaunchTargetResolver.resolve(
            storedProfileID: "codex-hooks",
            installed: []
        )
        XCTAssertNil(resolved)
    }

    func testLaunchTargetPersistenceRoundTrip() {
        let suiteName = "AICOSLaunchTargetResolverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(AICOSLaunchTargetResolver.loadStoredProfileID(defaults: defaults))
        AICOSLaunchTargetResolver.setStoredProfileID("zcode-hooks", defaults: defaults)
        XCTAssertEqual(AICOSLaunchTargetResolver.loadStoredProfileID(defaults: defaults), "zcode-hooks")
        AICOSLaunchTargetResolver.setStoredProfileID("", defaults: defaults)
        XCTAssertNil(AICOSLaunchTargetResolver.loadStoredProfileID(defaults: defaults))
    }
}
