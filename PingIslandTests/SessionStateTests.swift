import Foundation
import XCTest
@testable import Ping_Island

final class SessionStateTests: XCTestCase {
    func testClosedNotchMascotStatusReturnsWorkingAfterWarningsClearForLiveSession() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .idle,
                hasPendingPermission: false,
                hasHumanIntervention: false
            ),
            .working
        )
    }

    func testClosedNotchMascotStatusKeepsWarningWhileAttentionIsPending() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .processing,
                hasPendingPermission: true,
                hasHumanIntervention: false
            ),
            .warning
        )
    }

    func testClosedNotchMascotStatusReturnsIdleWhenOnlyEndedSessionRemains() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .ended,
                hasPendingPermission: false,
                hasHumanIntervention: false
            ),
            .idle
        )
    }

    func testDisplayTitleFallsBackToSummaryThenFirstUserMessage() {
        let withSummary = SessionState(
            sessionId: "summary-session",
            cwd: "/tmp/project",
            conversationInfo: ConversationInfo(
                summary: "Ship release",
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: "Help me ship",
                lastUserMessageDate: nil
            )
        )
        let withFirstUserMessage = SessionState(
            sessionId: "first-user-session",
            cwd: "/tmp/project",
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: "Fix the menu bar bug",
                lastUserMessageDate: nil
            )
        )

        XCTAssertEqual(withSummary.displayTitle, "Ship release")
        XCTAssertEqual(withFirstUserMessage.displayTitle, "Fix the menu bar bug")
    }

    func testHeuristicSubagentDisplayTitleUsesTitleOnlyPresentation() {
        let session = SessionState(
            sessionId: "qoder-heuristic-subagent",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .qoder, profileID: "qoder", name: "Qoder"),
            heuristicSubagentDisplayTitle: "Agent · Read File README.md"
        )

        XCTAssertTrue(session.isHeuristicSubagentSession)
        XCTAssertTrue(session.usesTitleOnlySubagentPresentation)
        XCTAssertEqual(session.primarySubagentVisibilityLevel, 1)
        XCTAssertEqual(session.titleOnlySubagentDisplayTitle, "Agent · Read File README.md")
    }

    func testQoderAgentPrefixedDisplayTitleUsesCodexStyleSubagentRendering() {
        let session = SessionState(
            sessionId: "qoder-agent-prefix",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .qoder, profileID: "qoder", name: "Qoder"),
            sessionName: "Agent · 读取 README 文件"
        )

        XCTAssertTrue(session.isQoderAgentPrefixedSubagent)
        XCTAssertTrue(session.usesTitleOnlySubagentPresentation)
        XCTAssertTrue(session.shouldUseCodexSubagentCompactPresentation)
        XCTAssertEqual(session.codexSubagentBadgeText, "SUBAGENT")
        XCTAssertEqual(session.primarySubagentVisibilityLevel, 1)
        XCTAssertEqual(session.titleOnlySubagentDisplayTitle, "Agent · 读取 README 文件")
    }

    func testActiveQueueSortActivityDatePrefersLiveActivityOverOlderTranscriptUserTimestamp() {
        let now = Date()
        let session = SessionState(
            sessionId: "active-session",
            cwd: "/tmp/project",
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "Working",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Do the work",
                lastUserMessageDate: now.addingTimeInterval(-120)
            ),
            lastActivity: now
        )

        XCTAssertEqual(session.queueSortActivityDate, now)
    }

    func testIdleQueueSortActivityDateStillUsesLastUserMessageDateWhenPresent() {
        let now = Date()
        let lastUserMessageDate = now.addingTimeInterval(-60)
        let session = SessionState(
            sessionId: "idle-session",
            cwd: "/tmp/project",
            phase: .idle,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "Done",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Finish the task",
                lastUserMessageDate: lastUserMessageDate
            ),
            lastActivity: now
        )

        XCTAssertEqual(session.queueSortActivityDate, lastUserMessageDate)
    }

    func testActiveSessionSortDoesNotDropBehindOlderIdleSessionWhenTranscriptBackfills() {
        let now = Date()
        let activeSession = SessionState(
            sessionId: "active-session",
            cwd: "/tmp/project",
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "Working",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Do the work",
                lastUserMessageDate: now.addingTimeInterval(-120)
            ),
            lastActivity: now
        )
        let idleSession = SessionState(
            sessionId: "idle-session",
            cwd: "/tmp/project",
            phase: .idle,
            lastActivity: now.addingTimeInterval(-20)
        )

        XCTAssertTrue(activeSession.shouldSortBeforeInQueue(idleSession))
    }

    func testActiveSessionSortsAheadOfWaitingForInputSession() {
        let now = Date()
        let activeSession = SessionState(
            sessionId: "active-session",
            cwd: "/tmp/project",
            phase: .processing,
            lastActivity: now
        )
        let waitingSession = SessionState(
            sessionId: "waiting-session",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            lastActivity: now.addingTimeInterval(-5)
        )

        XCTAssertTrue(activeSession.shouldSortBeforeInQueue(waitingSession))
        XCTAssertFalse(waitingSession.shouldSortBeforeInQueue(activeSession))
    }

    func testCompactHookMessageNormalizesWhitespace() {
        let session = SessionState(
            sessionId: "hook-message",
            cwd: "/tmp/project",
            latestHookMessage: "  Claude\n   needs   approval  "
        )

        XCTAssertEqual(session.compactHookMessage, "Claude needs approval")
    }

    func testCompactHookMessageHidesStopMessage() {
        let session = SessionState(
            sessionId: "stop-hook-message",
            cwd: "/tmp/project",
            latestHookMessage: "  Stop  "
        )

        XCTAssertNil(session.compactHookMessage)
    }

    func testWaitingForApprovalPhaseSurfacesPendingToolDetails() {
        let permission = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: [
                "command": AnyCodable("swift test"),
                "timeout": AnyCodable(30)
            ],
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        let session = SessionState(
            sessionId: "approval-session",
            cwd: "/tmp/project",
            phase: .waitingForApproval(permission)
        )

        XCTAssertTrue(session.needsApprovalResponse)
        XCTAssertEqual(session.pendingToolName, "Bash")
        XCTAssertEqual(session.pendingToolId, "tool-1")
        XCTAssertEqual(session.pendingToolInput, "command: swift test\ntimeout: 30")
    }

    func testClaudeCodeWaitingForApprovalSupportsAutoApproveAction() {
        let session = SessionState(
            sessionId: "claude-auto-approve",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertEqual(session.scopedApprovalAction, .autoApprove)
        XCTAssertTrue(session.supportsSessionScopedApproval)
        XCTAssertEqual(SessionScopedApprovalAction.autoApprove.buttonTitleKey, "Always Allow")
        XCTAssertEqual(SessionScopedApprovalAction.autoApprove.compactButtonTitleKey, "Always")
    }

    func testQoderWaitingForApprovalDoesNotExposeClaudeAutoApproveAction() {
        let session = SessionState(
            sessionId: "qoder-no-auto-approve",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .qoder, profileID: "qoder", name: "Qoder"),
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertNil(session.scopedApprovalAction)
        XCTAssertFalse(session.supportsSessionScopedApproval)
    }

    func testCodexAppServerWaitingForApprovalUsesAllowSessionAction() {
        let session = SessionState(
            sessionId: "codex-session-scope",
            cwd: "/tmp/project",
            provider: .codex,
            ingress: .codexAppServer,
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "shell", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertEqual(session.scopedApprovalAction, .allowSession)
    }

    func testCodexDepthOneChildSessionIsRecognizedAsSubagent() {
        let session = SessionState(
            sessionId: "codex-subagent-depth-one",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-parent",
            codexSubagentDepth: 1,
            codexSubagentNickname: "Avicenna",
            codexSubagentRole: "analyst"
        )

        XCTAssertEqual(session.codexSubagentLevel, 1)
        XCTAssertTrue(session.isCodexSubagent)
        XCTAssertEqual(session.codexSubagentBadgeText, "SUBAGENT")
        XCTAssertEqual(session.subagentClientTypeBadgeText, "Codex")
        XCTAssertEqual(session.codexSubagentLabel, "Subagent · analyst · Avicenna")
    }

    func testCodexSubagentUsesCompactPrimaryPresentation() {
        let session = SessionState(
            sessionId: "codex-subagent-compact",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-parent",
            codexSubagentDepth: 1,
            codexSubagentNickname: "Avicenna",
            codexSubagentRole: "analyst",
            lastActivity: Date()
        )

        XCTAssertTrue(session.shouldUseCodexSubagentCompactPresentation)
        XCTAssertFalse(session.shouldUseMinimalCompactPresentation)
    }

    func testIdleSessionAutoArchivesFromPrimaryUIAfterThirtyMinutes() {
        let session = SessionState(
            sessionId: "idle-auto-archive",
            cwd: "/tmp/project",
            lastActivity: Date().addingTimeInterval(-(31 * 60))
        )

        XCTAssertTrue(session.shouldAutoArchiveFromPrimaryUI)
        XCTAssertTrue(session.shouldHideFromPrimaryUI)
        XCTAssertFalse(session.shouldUseMinimalCompactPresentation)
    }

    func testAttentionSessionStaysVisibleAfterThirtyMinutes() {
        let permission = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        let session = SessionState(
            sessionId: "attention-visible",
            cwd: "/tmp/project",
            phase: .waitingForApproval(permission),
            lastActivity: Date().addingTimeInterval(-(31 * 60))
        )

        XCTAssertFalse(session.shouldAutoArchiveFromPrimaryUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
    }

    func testEndedSessionShowsArchiveActionAfterTenMinutes() {
        let session = SessionState(
            sessionId: "ended-archive-eligible",
            cwd: "/tmp/project",
            phase: .ended,
            lastActivity: Date().addingTimeInterval(-(11 * 60))
        )

        XCTAssertTrue(session.shouldShowArchiveActionInPrimaryUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
        XCTAssertFalse(session.shouldUseMinimalCompactPresentation)
    }

    func testRecentlyEndedSessionDoesNotShowArchiveActionYet() {
        let session = SessionState(
            sessionId: "ended-archive-waiting",
            cwd: "/tmp/project",
            phase: .ended,
            lastActivity: Date().addingTimeInterval(-(9 * 60))
        )

        XCTAssertFalse(session.shouldShowArchiveActionInPrimaryUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
    }

    func testIdleSessionStillShowsArchiveActionImmediately() {
        let session = SessionState(
            sessionId: "idle-archive-immediate",
            cwd: "/tmp/project",
            phase: .idle,
            lastActivity: Date().addingTimeInterval(-60)
        )

        XCTAssertTrue(session.shouldShowArchiveActionInPrimaryUI)
    }

    func testNativeRuntimeSessionExposesTerminateActionUntilEnded() {
        let activeSession = SessionState(
            sessionId: "native-active",
            cwd: "/tmp/project",
            ingress: .nativeRuntime,
            phase: .processing
        )
        let endedSession = SessionState(
            sessionId: "native-ended",
            cwd: "/tmp/project",
            ingress: .nativeRuntime,
            phase: .ended
        )

        XCTAssertTrue(activeSession.isNativeRuntimeSession)
        XCTAssertTrue(activeSession.shouldShowTerminateActionInPrimaryUI)
        XCTAssertTrue(endedSession.isNativeRuntimeSession)
        XCTAssertFalse(endedSession.shouldShowTerminateActionInPrimaryUI)
    }

    func testCodexAppLaunchURLUsesThreadsRoute() {
        let threadID = "019d6163-2ee9-7ae2-8c45-5f7a16209149"

        XCTAssertEqual(
            SessionClientInfo.appLaunchURL(
                bundleIdentifier: "com.openai.codex",
                sessionId: threadID
            ),
            "codex://threads/\(threadID)"
        )
    }

    func testQoderWorkLaunchURLUsesQoderWorkScheme() {
        XCTAssertEqual(
            SessionClientInfo.appLaunchURL(
                bundleIdentifier: "com.qoder.work",
                workspacePath: "/tmp/project"
            ),
            "qoder-work://file/tmp/project"
        )
    }

    func testCodexAppNormalizationUpgradesLegacyLocalDeepLinks() {
        let threadID = "019d6163-2ee9-7ae2-8c45-5f7a16209149"
        let normalized = SessionClientInfo(
            kind: .codexApp,
            bundleIdentifier: "com.openai.codex",
            launchURL: "codex://local/\(threadID)"
        ).normalizedForCodexRouting(sessionId: threadID)

        XCTAssertEqual(normalized.launchURL, "codex://threads/\(threadID)")
    }

    func testEmptyCodexPlaceholderHidesWhenRicherThreadMatchesSameWorkspaceSurface() {
        let now = Date()
        let placeholder = SessionState(
            sessionId: "codex-empty",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                originator: "Cursor",
                terminalBundleIdentifier: "com.todesktop.230313mzl4w4u92"
            ),
            lastActivity: now
        )
        let richerSession = SessionState(
            sessionId: "codex-real",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                originator: "Cursor",
                sessionFilePath: "/tmp/project/.codex/sessions/real.jsonl",
                terminalBundleIdentifier: "com.todesktop.230313mzl4w4u92"
            ),
            previewText: "Finish the refactor",
            lastActivity: now.addingTimeInterval(-30)
        )

        XCTAssertTrue(placeholder.isLikelyEmptyCodexPlaceholderForUI)
        XCTAssertTrue(placeholder.shouldHideAsDuplicateCodexPlaceholder(comparedTo: richerSession))
    }

    func testEmptyCodexPlaceholderDoesNotHideAnotherRealThreadInSameWorkspace() {
        let now = Date()
        let firstRealSession = SessionState(
            sessionId: "codex-real-1",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                originator: "Codex",
                sessionFilePath: "/tmp/project/.codex/sessions/one.jsonl"
            ),
            previewText: "Investigate duplicated sessions",
            lastActivity: now
        )
        let secondRealSession = SessionState(
            sessionId: "codex-real-2",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                originator: "Codex",
                sessionFilePath: "/tmp/project/.codex/sessions/two.jsonl"
            ),
            previewText: "Polish the hover layout",
            lastActivity: now.addingTimeInterval(-10)
        )

        XCTAssertFalse(firstRealSession.shouldHideAsDuplicateCodexPlaceholder(comparedTo: secondRealSession))
        XCTAssertFalse(secondRealSession.shouldHideAsDuplicateCodexPlaceholder(comparedTo: firstRealSession))
    }

    func testCodexDepthOneChildThreadUsesSubagentPresentation() {
        let session = SessionState(
            sessionId: "codex-subagent",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-parent",
            codexSubagentDepth: 1,
            codexSubagentNickname: "Kierkegaard",
            codexSubagentRole: "explorer"
        )

        XCTAssertEqual(session.codexSubagentLevel, 1)
        XCTAssertTrue(session.isCodexSubagent)
        XCTAssertEqual(session.codexSubagentBadgeText, "SUBAGENT")
        XCTAssertEqual(session.codexSubagentLabel, "Subagent · explorer · Kierkegaard")
        XCTAssertEqual(
            session.codexSubagentSummaryText(for: "I checked the repo"),
            "Subagent · explorer · Kierkegaard · I checked the repo"
        )
    }

    func testCodexSubagentLabelIncludesRoleAndNickname() {
        let session = SessionState(
            sessionId: "codex-subagent",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-parent",
            codexSubagentDepth: 2,
            codexSubagentNickname: "Kierkegaard",
            codexSubagentRole: "explorer"
        )

        XCTAssertEqual(session.codexSubagentLevel, 2)
        XCTAssertTrue(session.isCodexSubagent)
        XCTAssertEqual(session.codexSubagentBadgeText, "SUBAGENT")
        XCTAssertEqual(session.codexSubagentLabel, "Subagent · explorer · Kierkegaard")
        XCTAssertEqual(session.codexSubagentListTitle, "Subagent · explorer · Kierkegaard")
        XCTAssertEqual(
            session.codexSubagentSummaryText(for: "I checked the repo"),
            "Subagent · explorer · Kierkegaard · I checked the repo"
        )
    }

    func testCodexCLISubagentKeepsCodexClientTypeBadge() {
        let session = SessionState(
            sessionId: "codex-cli-subagent",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex CLI",
                originator: "iTerm2",
                terminalBundleIdentifier: "com.googlecode.iterm2",
                terminalProgram: "iTerm.app"
            ),
            codexParentThreadId: "codex-parent",
            codexSubagentDepth: 1
        )

        XCTAssertEqual(session.clientDisplayName, "Codex")
        XCTAssertEqual(session.subagentClientTypeBadgeText, "Codex")
    }

    func testLinkedQoderChildUsesQoderClientTypeBadge() {
        let session = SessionState(
            sessionId: "qoder-linked-subagent",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder",
                name: "Qoder"
            ),
            linkedParentSessionId: "qoder-parent",
            linkedSubagentDisplayTitle: "Agent · 读取README文件"
        )

        XCTAssertTrue(session.usesTitleOnlySubagentPresentation)
        XCTAssertEqual(session.subagentClientTypeBadgeText, "Qoder")
    }

    func testSubagentVisibilityModeHidesExplicitChildrenWhenDisabled() {
        let parent = SessionState(
            sessionId: "codex-parent",
            cwd: "/tmp/project",
            provider: .codex
        )
        let parentAgent = SessionState(
            sessionId: "codex-parent-agent",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-parent",
            codexSubagentDepth: 1,
            codexSubagentNickname: "Kierkegaard",
            codexSubagentRole: "explorer"
        )
        let firstLevelChild = SessionState(
            sessionId: "codex-child-1",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-parent-agent",
            codexSubagentDepth: 2,
            codexSubagentNickname: "Ampere",
            codexSubagentRole: "explorer"
        )
        let nestedChild = SessionState(
            sessionId: "codex-child-2",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-child-1",
            codexSubagentDepth: 3,
            codexSubagentNickname: "Turing",
            codexSubagentRole: "explorer"
        )

        XCTAssertTrue(parent.shouldDisplaySubagent(in: .hidden))
        XCTAssertFalse(parentAgent.shouldDisplaySubagent(in: .hidden))
        XCTAssertFalse(firstLevelChild.shouldDisplaySubagent(in: .hidden))
        XCTAssertTrue(firstLevelChild.shouldDisplaySubagent(in: .visible))
        XCTAssertTrue(nestedChild.shouldDisplaySubagent(in: .visible))
    }

    func testPrimarySessionGroupsNestExplicitSubagentsUnderRootParent() {
        let parent = SessionState(
            sessionId: "codex-parent",
            cwd: "/tmp/project",
            provider: .codex,
            phase: .processing,
            lastActivity: Date(timeIntervalSince1970: 100)
        )
        let child = SessionState(
            sessionId: "codex-child",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-parent",
            codexSubagentDepth: 1,
            codexSubagentNickname: "Search API endpoints",
            codexSubagentRole: "explore",
            phase: .processing,
            lastActivity: Date(timeIntervalSince1970: 110)
        )
        let nestedChild = SessionState(
            sessionId: "codex-nested-child",
            cwd: "/tmp/project",
            provider: .codex,
            codexParentThreadId: "codex-child",
            codexSubagentDepth: 2,
            codexSubagentNickname: "handleRequest",
            codexSubagentRole: "explore",
            phase: .processing,
            lastActivity: Date(timeIntervalSince1970: 120)
        )

        let groups = PrimarySessionGroup.groups(from: [nestedChild, child, parent])

        XCTAssertEqual(groups.map(\.session.sessionId), ["codex-parent"])
        XCTAssertEqual(groups.first?.childSessions.map(\.sessionId), ["codex-nested-child", "codex-child"])
    }

    func testSubagentVisibilityModeAppliesToLinkedChildSessions() {
        let qoderChild = SessionState(
            sessionId: "qoder-child",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .qoder, profileID: "qoder", name: "Qoder"),
            linkedParentSessionId: "qoder-parent",
            linkedSubagentDisplayTitle: "Agent · 读取 README"
        )

        XCTAssertFalse(qoderChild.shouldDisplaySubagent(in: .hidden))
        XCTAssertTrue(qoderChild.shouldDisplaySubagent(in: .visible))
    }

    func testOpenCodeChildPlaceholderHidesWhenRicherParentMatchesSameSurface() {
        let now = Date()
        let parent = SessionState(
            sessionId: "opencode-parent",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .custom,
                profileID: "opencode",
                name: "OpenCode",
                origin: "cli",
                originator: "OpenCode",
                threadSource: "opencode-plugin",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty",
                terminalSessionIdentifier: "ghostty-session-1"
            ),
            previewText: "Fix duplicate sessions in the menu bar",
            phase: .processing,
            lastActivity: now.addingTimeInterval(-15),
            createdAt: now.addingTimeInterval(-60)
        )
        let child = SessionState(
            sessionId: "opencode-child",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .custom,
                profileID: "opencode",
                name: "OpenCode",
                origin: "cli",
                originator: "OpenCode",
                threadSource: "opencode-plugin",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty",
                terminalSessionIdentifier: "ghostty-session-1"
            ),
            previewText: "Working...",
            phase: .processing,
            lastActivity: now,
            createdAt: now.addingTimeInterval(-10)
        )

        XCTAssertTrue(child.isLikelyOpenCodeChildSessionPlaceholderForUI)
        XCTAssertTrue(parent.hasDurableOpenCodeDisplayIdentity)
        XCTAssertTrue(child.shouldHideAsDuplicateOpenCodeChildSession(comparedTo: parent))
    }

    func testOpenCodeRealSessionDoesNotHideAnotherRealSessionOnSameSurface() {
        let now = Date()
        let firstSession = SessionState(
            sessionId: "opencode-real-1",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .custom,
                profileID: "opencode",
                name: "OpenCode",
                origin: "cli",
                originator: "OpenCode",
                threadSource: "opencode-plugin",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty",
                terminalSessionIdentifier: "ghostty-session-1"
            ),
            previewText: "Investigate working state detection",
            phase: .processing,
            lastActivity: now.addingTimeInterval(-20),
            createdAt: now.addingTimeInterval(-120)
        )
        let secondSession = SessionState(
            sessionId: "opencode-real-2",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .custom,
                profileID: "opencode",
                name: "OpenCode",
                origin: "cli",
                originator: "OpenCode",
                threadSource: "opencode-plugin",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty",
                terminalSessionIdentifier: "ghostty-session-1"
            ),
            previewText: "Write regression tests for child sessions",
            phase: .processing,
            lastActivity: now,
            createdAt: now.addingTimeInterval(-30)
        )

        XCTAssertFalse(firstSession.isLikelyOpenCodeChildSessionPlaceholderForUI)
        XCTAssertFalse(secondSession.isLikelyOpenCodeChildSessionPlaceholderForUI)
        XCTAssertFalse(firstSession.shouldHideAsDuplicateOpenCodeChildSession(comparedTo: secondSession))
        XCTAssertFalse(secondSession.shouldHideAsDuplicateOpenCodeChildSession(comparedTo: firstSession))
    }

    func testGenericEmptyCodexPlaceholderHidesWhenNearbyThreadHasRolloutPath() {
        let now = Date()
        let placeholder = SessionState(
            sessionId: "codex-empty-generic",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexApp),
            lastActivity: now
        )
        let richerSession = SessionState(
            sessionId: "codex-real-generic",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                sessionFilePath: "/tmp/project/.codex/sessions/real.jsonl"
            ),
            conversationInfo: ConversationInfo(
                summary: "Tighten session dedupe",
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            lastActivity: now.addingTimeInterval(-45)
        )

        XCTAssertTrue(placeholder.shouldHideAsDuplicateCodexPlaceholder(comparedTo: richerSession))
    }

    func testCodexContinuationPlaceholderRebindsToRecentRicherThreadInSameWorkspace() {
        let now = Date()
        let continuationPlaceholder = SessionState(
            sessionId: "codex-placeholder",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexApp),
            latestHookMessage: "Codex: 工作中...",
            phase: .processing,
            lastActivity: now
        )
        let richerSession = SessionState(
            sessionId: "codex-existing",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                sessionFilePath: "/tmp/project/.codex/sessions/rollout-existing.jsonl"
            ),
            sessionName: "Support QoderWork client recognition",
            previewText: "Ready to patch the routing logic",
            conversationInfo: ConversationInfo(
                summary: "Support QoderWork client recognition",
                lastMessage: "Ready to patch the routing logic",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Support QoderWork client recognition",
                lastUserMessageDate: now.addingTimeInterval(-60)
            ),
            lastActivity: now.addingTimeInterval(-4 * 60)
        )

        XCTAssertTrue(continuationPlaceholder.isLikelyTransientCodexContinuationPlaceholder)
        XCTAssertTrue(continuationPlaceholder.shouldHideAsDuplicateCodexPlaceholder(comparedTo: richerSession))
    }

    func testCodexContinuationPlaceholderDoesNotRebindWhenExistingThreadIsTooOld() {
        let now = Date()
        let continuationPlaceholder = SessionState(
            sessionId: "codex-placeholder-old-gap",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexApp),
            latestHookMessage: "Codex: 工作中...",
            phase: .processing,
            lastActivity: now
        )
        let staleSession = SessionState(
            sessionId: "codex-existing-old-gap",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                sessionFilePath: "/tmp/project/.codex/sessions/rollout-existing.jsonl"
            ),
            sessionName: "Old thread",
            lastActivity: now.addingTimeInterval(-(20 * 60))
        )

        XCTAssertFalse(
            continuationPlaceholder.shouldRebindToExistingCodexThread(
                comparedTo: staleSession,
                maximumRecencyGap: 10 * 60
            )
        )
    }

    func testQoderCLINormalizationKeepsCLIIdentity() {
        let normalized = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder",
            name: "Qoder",
            terminalBundleIdentifier: "com.googlecode.iterm2",
            terminalProgram: "iTerm.app"
        ).normalizedForClaudeRouting()

        XCTAssertEqual(normalized.profileID, "qoder-cli")
        XCTAssertEqual(normalized.name, "Qoder CLI")
        XCTAssertEqual(normalized.badgeLabel(for: .claude), "Qoder CLI")
        XCTAssertEqual(normalized.interactionLabel(for: .claude), "Qoder CLI")
        XCTAssertNil(normalized.ideHostBadgeLabel(for: .claude))
    }

    func testTerminalHostedGhosttySessionShowsSourceBadge() {
        let session = SessionState(
            sessionId: "ghostty-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                name: "Claude Code",
                originator: "Ghostty",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty"
            )
        )

        XCTAssertEqual(session.terminalSourceBadgeLabel, "Ghostty")
        XCTAssertEqual(session.clientInfo.terminalContextSummary, "Ghostty")
    }

    func testTerminalHostedWezTermSessionShowsSourceBadge() {
        let session = SessionState(
            sessionId: "wezterm-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                name: "Claude Code",
                originator: "WezTerm",
                terminalBundleIdentifier: "com.github.wez.wezterm",
                terminalProgram: "WezTerm"
            )
        )

        XCTAssertEqual(session.terminalSourceBadgeLabel, "WezTerm")
        XCTAssertEqual(session.clientInfo.terminalContextSummary, "WezTerm")
    }

    func testTerminalContextSummaryDeduplicatesTerminalOriginatorAndRemoteContext() {
        let clientInfo = SessionClientInfo(
            kind: .codexCLI,
            name: "Codex CLI",
            originator: "Ghostty",
            transport: "ssh-remote",
            remoteHost: "devbox",
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            terminalProgram: "ghostty"
        )

        XCTAssertEqual(clientInfo.terminalContextSummary, "Ghostty · ssh-remote@devbox")
    }

    func testRemoteBridgeSessionIsMarkedRemote() {
        let session = SessionState(
            sessionId: "remote-bridge-session",
            cwd: "/tmp/project",
            ingress: .remoteBridge
        )

        XCTAssertTrue(session.isRemoteSession)
    }

    func testSSHContextSessionIsMarkedRemote() {
        let session = SessionState(
            sessionId: "ssh-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                name: "Claude Code",
                transport: "ssh-remote",
                remoteHost: "devbox"
            )
        )

        XCTAssertTrue(session.isRemoteSession)
    }

    func testLocalSessionIsNotMarkedRemote() {
        let session = SessionState(
            sessionId: "local-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                name: "Claude Code",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty"
            )
        )

        XCTAssertFalse(session.isRemoteSession)
    }

    func testCodexCLIInteractionLabelPrefersTerminalHost() {
        let session = SessionState(
            sessionId: "codex-ghostty-interaction",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty"
            )
        )

        XCTAssertEqual(session.clientDisplayName, "Ghostty")
        XCTAssertEqual(session.interactionDisplayName, "Ghostty")
        XCTAssertNil(session.terminalSourceBadgeLabel)
    }

    func testQwenCodeInteractionLabelPrefersTerminalHost() {
        let session = SessionState(
            sessionId: "qwen-ghostty-interaction",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .custom,
                profileID: "qwen-code",
                name: "Qwen Code",
                originator: "Ghostty",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty"
            )
        )

        XCTAssertEqual(session.clientDisplayName, "Qwen Code")
        XCTAssertEqual(session.interactionDisplayName, "Ghostty")
        XCTAssertEqual(session.terminalSourceBadgeLabel, "Ghostty")
    }

    func testCodexAppMessageBadgeUsesProviderName() {
        let appSession = SessionState(
            sessionId: "codex-app-session",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                name: "Codex App",
                bundleIdentifier: "com.openai.codex"
            )
        )
        let cliSession = SessionState(
            sessionId: "codex-cli-session",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                name: "Codex CLI"
            )
        )

        XCTAssertEqual(appSession.clientDisplayName, "Codex App")
        XCTAssertEqual(appSession.providerDisplayName, "Codex")
        XCTAssertEqual(appSession.messageBadgeDisplayName, "Codex")
        XCTAssertEqual(cliSession.messageBadgeDisplayName, cliSession.clientDisplayName)
    }

    func testTerminalHostedCodexCLIUsesCodexPrimaryAndITermAsTerminalBadge() {
        let session = SessionState(
            sessionId: "codex-iterm-session",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex CLI",
                originator: "iTerm2",
                terminalBundleIdentifier: "com.googlecode.iterm2",
                terminalProgram: "iTerm.app",
                terminalSessionIdentifier: "iterm-session-1"
            )
        )

        XCTAssertEqual(session.providerDisplayName, "Codex")
        XCTAssertEqual(session.clientDisplayName, "Codex")
        XCTAssertEqual(session.messageBadgeDisplayName, "Codex")
        XCTAssertEqual(session.interactionDisplayName, "iTerm2")
        XCTAssertEqual(session.terminalSourceBadgeLabel, "iTerm2")
    }

    func testCodexTerminalSourceBadgeIsHiddenWhenItDuplicatesPrimaryBadge() {
        let session = SessionState(
            sessionId: "codex-duplicate-badge",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                terminalBundleIdentifier: "com.openai.codex"
            )
        )

        XCTAssertEqual(session.messageBadgeDisplayName, "Codex")
        XCTAssertNil(session.terminalSourceBadgeLabel)
    }

    func testIDEHostedSessionsDoNotShowTerminalSourceBadge() {
        let session = SessionState(
            sessionId: "cursor-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                name: "Claude Code",
                originator: "Cursor",
                terminalBundleIdentifier: "com.todesktop.230313mzl4w4u92"
            )
        )

        XCTAssertNil(session.terminalSourceBadgeLabel)
        XCTAssertEqual(session.ideHostBadgeLabel, "Cursor 终端")
    }

    func testIDEHostedQoderNormalizationKeepsIDEIdentity() {
        let normalized = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder",
            name: "Qoder",
            terminalBundleIdentifier: "com.qoder.ide"
        ).normalizedForClaudeRouting()

        XCTAssertEqual(normalized.profileID, "qoder")
        XCTAssertEqual(normalized.name, "Qoder")
        XCTAssertEqual(normalized.badgeLabel(for: .claude), "Qoder")
        XCTAssertEqual(normalized.interactionLabel(for: .claude), "Qoder")
    }

    func testIDEHostedQoderCLIMetadataNormalizesBackToIDEIdentity() {
        let normalized = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder-cli",
            name: "Qoder CLI",
            origin: "cli",
            originator: "Qoder",
            terminalBundleIdentifier: "com.qoder.ide"
        ).normalizedForClaudeRouting()

        XCTAssertEqual(normalized.profileID, "qoder")
        XCTAssertEqual(normalized.name, "Qoder")
        XCTAssertEqual(normalized.badgeLabel(for: .claude), "Qoder")
        XCTAssertEqual(normalized.interactionLabel(for: .claude), "Qoder")
    }

    func testQoderWorkDoesNotResolveToIDEExtensionHost() {
        let normalized = SessionClientInfo(
            kind: .qoder,
            profileID: "qoderwork",
            name: "QoderWork",
            terminalBundleIdentifier: "com.qoder.work"
        ).normalizedForClaudeRouting()

        XCTAssertEqual(normalized.profileID, "qoderwork")
        XCTAssertEqual(normalized.name, "QoderWork")
        XCTAssertEqual(normalized.badgeLabel(for: .claude), "QoderWork")
        XCTAssertEqual(normalized.interactionLabel(for: .claude), "QoderWork")
        XCTAssertNil(normalized.ideHostProfile)
        XCTAssertFalse(normalized.isHostedInIDE)
        XCTAssertNil(normalized.ideHostBadgeLabel(for: .claude))
    }

    func testQoderWorkDoesNotMatchAnyIDEExtensionProfile() {
        let bundleProfile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: "com.qoder.work",
            appName: "QoderWork"
        )
        let nameOnlyProfile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: nil,
            appName: "QoderWork"
        )
        let spacedNameProfile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: nil,
            appName: "Qoder Work"
        )

        XCTAssertNil(bundleProfile)
        XCTAssertNil(nameOnlyProfile)
        XCTAssertNil(spacedNameProfile)
    }

    func testIDEExtensionInstallerPrefersInstalledAppDataFolderName() throws {
        let appURL = try makeFakeVSCodeCompatibleApp(dataFolderName: ".resolved-codebuddy")
        let profile = try XCTUnwrap(ClientProfileRegistry.ideExtensionProfile(id: "codebuddy-extension"))

        let rootURLs = IDEExtensionInstaller.candidateExtensionRootURLs(
            for: profile,
            resolvedInstalledAppURLs: [appURL]
        )

        let expectedRootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".resolved-codebuddy", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)

        XCTAssertEqual(rootURLs.first?.standardizedFileURL.path, expectedRootURL.standardizedFileURL.path)
        XCTAssertTrue(
            rootURLs.contains { rootURL in
                rootURL.standardizedFileURL.path == profile.primaryExtensionRootURL.standardizedFileURL.path
            }
        )
    }

    func testCodeBuddyAndQoderProfilesDeclareExtensionRegistries() throws {
        let codeBuddyProfile = try XCTUnwrap(ClientProfileRegistry.ideExtensionProfile(id: "codebuddy-extension"))
        let qoderProfile = try XCTUnwrap(ClientProfileRegistry.ideExtensionProfile(id: "qoder-extension"))

        XCTAssertEqual(
            codeBuddyProfile.extensionRegistryURLs.map(\.path),
            [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codebuddy", isDirectory: true)
                    .appendingPathComponent("extensions", isDirectory: true)
                    .appendingPathComponent("extensions.json", isDirectory: false)
                    .path,
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codebuddycn", isDirectory: true)
                    .appendingPathComponent("extensions", isDirectory: true)
                    .appendingPathComponent("extensions.json", isDirectory: false)
                    .path
            ]
        )
        XCTAssertEqual(
            qoderProfile.extensionRegistryURLs.map(\.path),
            [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".qoder", isDirectory: true)
                    .appendingPathComponent("extensions", isDirectory: true)
                    .appendingPathComponent("extensions.json", isDirectory: false)
                    .path
            ]
        )
    }

    func testWorkBuddyRuntimeProfileMatchesBundleAndName() {
        let bundleProfile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: nil,
            explicitName: "WorkBuddy",
            explicitBundleIdentifier: "com.workbuddy.workbuddy",
            terminalBundleIdentifier: nil,
            origin: nil,
            originator: nil,
            threadSource: nil,
            processName: nil
        )
        let nameOnlyProfile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: nil,
            explicitName: "WorkBuddy",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: nil,
            originator: nil,
            threadSource: nil,
            processName: nil
        )

        XCTAssertEqual(bundleProfile?.id, "workbuddy")
        XCTAssertEqual(nameOnlyProfile?.id, "workbuddy")
        XCTAssertEqual(ClientProfileRegistry.ideExtensionProfile(bundleIdentifier: "com.workbuddy.workbuddy", appName: "WorkBuddy")?.id, "workbuddy-extension")
    }

    func testWorkBuddyWorkspaceLaunchURLUsesNativeScheme() {
        XCTAssertEqual(
            SessionClientInfo.appLaunchURL(
                bundleIdentifier: "com.workbuddy.workbuddy",
                workspacePath: "/tmp/project"
            ),
            "workbuddy://file/tmp/project"
        )
    }

    func testCodeBuddyCompletedFollowupQuestionShowsClientPrompt() {
        let session = SessionState(
            sessionId: "codebuddy-followup",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "codebuddy",
                name: "CodeBuddy",
                bundleIdentifier: "com.tencent.codebuddy"
            ),
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(
                    id: "tool-followup",
                    type: .toolCall(
                        ToolCallItem(
                            name: "ask_followup_question",
                            input: [:],
                            status: .success,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )
                    ),
                    timestamp: Date()
                )
            ]
        )

        XCTAssertNotNil(session.latestCompletedFollowupQuestionTool)
        XCTAssertTrue(session.shouldShowClientFollowupPrompt)
    }

    func testClientFollowupPromptShowsWhenLatestMessageIsCompletedFollowupQuestionEvenIfInterventionExists() {
        let session = SessionState(
            sessionId: "workbuddy-followup",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            ),
            intervention: SessionIntervention(
                id: "question-1",
                kind: .question,
                title: "WorkBuddy 的提问",
                message: "请回答",
                options: [],
                questions: [],
                supportsSessionScope: false,
                metadata: [:]
            ),
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(
                    id: "tool-followup",
                    type: .toolCall(
                        ToolCallItem(
                            name: "ask_followup_question",
                            input: [:],
                            status: .success,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )
                    ),
                    timestamp: Date()
                )
            ]
        )

        XCTAssertTrue(session.shouldShowClientFollowupPrompt)
    }

    func testClientFollowupPromptDoesNotShowWhenLatestMessageIsNotCompletedFollowupQuestion() {
        let session = SessionState(
            sessionId: "codebuddy-followup-running",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "codebuddy",
                name: "CodeBuddy",
                bundleIdentifier: "com.tencent.codebuddy"
            ),
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(
                    id: "tool-followup",
                    type: .toolCall(
                        ToolCallItem(
                            name: "ask_followup_question",
                            input: [:],
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )
                    ),
                    timestamp: Date()
                )
            ]
        )

        XCTAssertFalse(session.shouldShowClientFollowupPrompt)
    }

    func testClientFollowupPromptDoesNotShowWhenACompletedFollowupQuestionIsNotLatestMessage() {
        let session = SessionState(
            sessionId: "workbuddy-followup-earlier",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            ),
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(
                    id: "tool-followup",
                    type: .toolCall(
                        ToolCallItem(
                            name: "ask_followup_question",
                            input: [:],
                            status: .success,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )
                    ),
                    timestamp: Date().addingTimeInterval(-1)
                ),
                ChatHistoryItem(
                    id: "assistant-after",
                    type: .assistant("继续问你一个更具体的问题"),
                    timestamp: Date()
                )
            ]
        )

        XCTAssertNil(session.latestCompletedFollowupQuestionTool)
        XCTAssertFalse(session.shouldShowClientFollowupPrompt)
    }

    func testCodexAppPrefersDirectLaunchURLBeforeWorkspaceRouting() {
        XCTAssertTrue(
            SessionLauncher.shouldPrioritizeDirectLaunchURL(
                for: SessionClientInfo(
                    kind: .codexApp,
                    bundleIdentifier: "com.openai.codex",
                    launchURL: "codex://threads/thread-123"
                )
            )
        )
        XCTAssertFalse(
            SessionLauncher.shouldPrioritizeDirectLaunchURL(
                for: SessionClientInfo(
                    kind: .qoder,
                    bundleIdentifier: "com.qoder.work",
                    launchURL: "qoder-work://file/tmp/project"
                )
            )
        )
    }

    func testClientFallbackActivationKeepsTerminalWindowsScoped() {
        XCTAssertFalse(
            SessionLauncher.shouldActivateAllWindowsForClientFallback(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
        XCTAssertFalse(
            SessionLauncher.shouldActivateAllWindowsForClientFallback(
                bundleIdentifier: "com.openai.codex.helper"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldActivateAllWindowsForClientFallback(
                bundleIdentifier: "com.apple.finder"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldActivateAllWindowsForClientFallback(
                bundleIdentifier: "com.qoder.work"
            )
        )
    }

    func testQoderWorkClientApplicationFallbackIsPrioritized() {
        let qoderWork = SessionClientInfo(
            kind: .qoder,
            profileID: " qoderwork ",
            name: "Qoder Work",
            bundleIdentifier: "com.googlecode.iterm2",
            terminalBundleIdentifier: " com.qoder.work "
        )

        XCTAssertTrue(SessionLauncher.shouldPrioritizeClientApplicationFallback(for: qoderWork))
        XCTAssertEqual(
            SessionLauncher.clientApplicationBundleIdentifiers(for: qoderWork),
            ["com.qoder.work", "com.googlecode.iterm2"]
        )
    }

    func testGenericClientApplicationFallbackDoesNotPrependQoderWork() {
        let qoderCLI = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder-cli",
            name: "Qoder CLI",
            terminalBundleIdentifier: "com.googlecode.iterm2"
        )

        XCTAssertFalse(SessionLauncher.shouldPrioritizeClientApplicationFallback(for: qoderCLI))
        XCTAssertEqual(
            SessionLauncher.clientApplicationBundleIdentifiers(for: qoderCLI),
            ["com.googlecode.iterm2"]
        )
    }

    func testTerminalFallbackActivationRestoresGhosttyFamilyWindows() {
        XCTAssertTrue(
            SessionLauncher.shouldActivateAllWindowsForTerminalFallback(
                bundleIdentifier: "com.cmuxterm.app"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldActivateAllWindowsForTerminalFallback(
                bundleIdentifier: "com.mitchellh.ghostty"
            )
        )
        XCTAssertFalse(
            SessionLauncher.shouldActivateAllWindowsForTerminalFallback(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
    }

    func testTerminalFallbackDoesNotClaimExactITermOrTerminalActivation() {
        XCTAssertFalse(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
        XCTAssertFalse(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: "com.apple.Terminal"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: "com.mitchellh.ghostty"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: nil
            )
        )
    }

    func testTerminalHostedCodexDoesNotFallBackToCodexAppNavigation() {
        let terminalHostedCodex = SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            launchURL: "codex://threads/thread-123",
            terminalBundleIdentifier: "com.googlecode.iterm2",
            terminalProgram: "iTerm.app",
            iTermSessionIdentifier: "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556"
        )

        XCTAssertTrue(
            SessionLauncher.isTerminalHostedCodexSession(
                provider: .codex,
                clientInfo: terminalHostedCodex
            )
        )
        XCTAssertFalse(
            SessionLauncher.allowsAppFallback(
                provider: .codex,
                clientInfo: terminalHostedCodex
            )
        )
    }

    func testTerminalHostedQoderCLIDoesNotFallBackToQoderAppNavigation() {
        let terminalHostedQoderCLI = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder-cli",
            name: "Qoder CLI",
            origin: "cli",
            originator: "Qoder",
            terminalBundleIdentifier: "com.googlecode.iterm2",
            terminalProgram: "iTerm.app",
            terminalSessionIdentifier: "w3t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556",
            iTermSessionIdentifier: "w3t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556"
        )

        XCTAssertTrue(
            SessionLauncher.isTerminalHostedQoderCLISession(
                provider: .claude,
                clientInfo: terminalHostedQoderCLI
            )
        )
        XCTAssertFalse(
            SessionLauncher.allowsAppFallback(
                provider: .claude,
                clientInfo: terminalHostedQoderCLI
            )
        )
    }

    func testNativeCodexAppStillAllowsAppNavigation() {
        let codexApp = SessionClientInfo.codexApp(threadId: "thread-123")

        XCTAssertFalse(
            SessionLauncher.isTerminalHostedCodexSession(
                provider: .codex,
                clientInfo: codexApp
            )
        )
        XCTAssertTrue(
            SessionLauncher.allowsAppFallback(
                provider: .codex,
                clientInfo: codexApp
            )
        )
    }

    func testConversationParserUsesFirstArrayBasedUserMessageAsFallbackTitle() async {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let transcriptURL = tempDirectory.appendingPathComponent("qoder-cli.jsonl")
        let content = """
        {"uuid":"meta","type":"user","timestamp":"2026-04-06T08:57:20.697Z","message":{"role":"user","content":[{"type":"text","text":"Caveat: ignore this"}]},"isMeta":true}
        {"uuid":"user-1","type":"user","timestamp":"2026-04-06T08:57:38.737Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"isMeta":false}
        {"uuid":"assistant-1","type":"assistant","timestamp":"2026-04-06T08:57:38.744Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi Dan! How can I help you today?"}]},"isMeta":false}
        """
        try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let info = await ConversationParser.shared.parse(
            sessionId: "qoder-cli-session",
            cwd: tempDirectory.path,
            explicitFilePath: transcriptURL.path
        )

        XCTAssertEqual(info.firstUserMessage, "hi")
        XCTAssertEqual(info.lastMessage, "Hi Dan! How can I help you today?")
        XCTAssertEqual(info.lastMessageRole, "assistant")
    }

    private func makeFakeVSCodeCompatibleApp(dataFolderName: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = rootURL.appendingPathComponent("FakeIDE.app", isDirectory: true)
        let productURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("product.json", isDirectory: false)

        try FileManager.default.createDirectory(
            at: productURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["dataFolderName": dataFolderName],
            options: []
        )
        try data.write(to: productURL, options: .atomic)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        return appURL
    }

    func testConversationParserStripsQoderWorkSystemReminderBlocks() async {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let transcriptURL = tempDirectory.appendingPathComponent("qoderwork.jsonl")
        let content = """
        {"uuid":"user-1","type":"user","timestamp":"2026-04-06T08:57:38.737Z","message":{"role":"user","content":[{"type":"text","text":"使用工具问我2个问题\\n\\n<system-reminder>\\nUser environment\\n</system-reminder>\\n<system-reminder>\\nAvailable MCP servers\\n</system-reminder>"}]},"isMeta":false}
        {"uuid":"assistant-1","type":"assistant","timestamp":"2026-04-06T08:57:38.744Z","message":{"role":"assistant","content":[{"type":"text","text":"请告诉我你的兴趣方向。"}]},"isMeta":false}
        """
        try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let info = await ConversationParser.shared.parse(
            sessionId: "qoderwork-session",
            cwd: tempDirectory.path,
            explicitFilePath: transcriptURL.path
        )

        XCTAssertEqual(info.firstUserMessage, "使用工具问我2个问题")
        XCTAssertEqual(info.lastMessage, "请告诉我你的兴趣方向。")
    }

    func testParseFullConversationStripsSystemReminderFromUserMessages() async {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let transcriptURL = tempDirectory.appendingPathComponent("qoderwork-chat.jsonl")
        let content = """
        {"uuid":"user-1","type":"user","timestamp":"2026-04-06T08:57:38.737Z","message":{"role":"user","content":[{"type":"text","text":"使用工具问我一个问题\\n\\n<system-reminder>\\nUser environment\\n</system-reminder>"}]},"isMeta":false}
        {"uuid":"assistant-1","type":"assistant","timestamp":"2026-04-06T08:57:38.744Z","message":{"role":"assistant","content":[{"type":"text","text":"好的，我来问你。"}]},"isMeta":false}
        """
        try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        await ConversationParser.shared.resetState(for: "qoderwork-chat-session")
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: "qoderwork-chat-session",
            cwd: tempDirectory.path,
            explicitFilePath: transcriptURL.path
        )

        XCTAssertEqual(messages.first?.textContent, "使用工具问我一个问题")
        XCTAssertEqual(messages.last?.textContent, "好的，我来问你。")
    }

    func testConversationParserReadsWorkBuddyHistoryIndexIncrementally() async throws {
        let sessionId = "workbuddy-history-\(UUID().uuidString)"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyDirectory = tempDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
        let messagesDirectory = historyDirectory.appendingPathComponent("messages", isDirectory: true)
        let indexURL = historyDirectory.appendingPathComponent("index.json")

        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        func writeMessage(id: String, role: String, blocks: [[String: Any]]) throws {
            let payload: [String: Any] = [
                "id": id,
                "role": role,
                "message": String(
                    data: try JSONSerialization.data(
                        withJSONObject: [
                            "role": role,
                            "content": blocks
                        ],
                        options: [.sortedKeys]
                    ),
                    encoding: .utf8
                ) ?? ""
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: messagesDirectory.appendingPathComponent("\(id).json"), options: .atomic)
        }

        func writeIndex(messageIDs: [(id: String, role: String)], requests: [[String: Any]]) throws {
            let payload: [String: Any] = [
                "messages": messageIDs.map { ["id": $0.id, "role": $0.role, "type": "text", "isComplete": true] },
                "requests": requests
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: indexURL, options: .atomic)
        }

        try writeMessage(
            id: "user-1",
            role: "user",
            blocks: [["type": "text", "text": "先记住我的偏好"]]
        )
        try writeMessage(
            id: "assistant-1",
            role: "assistant",
            blocks: [["type": "text", "text": "好的，我先记录下来。"]]
        )
        try writeIndex(
            messageIDs: [("user-1", "user"), ("assistant-1", "assistant")],
            requests: [[
                "id": "request-1",
                "messages": ["user-1", "assistant-1"],
                "startedAt": 1_776_006_000_000 as Int
            ]]
        )

        await ConversationParser.shared.resetState(for: sessionId)
        let initialMessages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: tempDirectory.path,
            explicitFilePath: indexURL.path
        )
        XCTAssertEqual(initialMessages.map(\.id), ["user-1", "assistant-1"])
        XCTAssertEqual(initialMessages.last?.textContent, "好的，我先记录下来。")

        try writeMessage(
            id: "assistant-2",
            role: "assistant",
            blocks: [["type": "text", "text": "搞定 ✅"]]
        )
        try writeIndex(
            messageIDs: [("user-1", "user"), ("assistant-1", "assistant"), ("assistant-2", "assistant")],
            requests: [
                [
                    "id": "request-1",
                    "messages": ["user-1", "assistant-1"],
                    "startedAt": 1_776_006_000_000 as Int
                ],
                [
                    "id": "request-2",
                    "messages": ["assistant-2"],
                    "startedAt": 1_776_006_060_000 as Int
                ]
            ]
        )

        let incremental = await ConversationParser.shared.parseIncremental(
            sessionId: sessionId,
            cwd: tempDirectory.path,
            explicitFilePath: indexURL.path
        )
        XCTAssertEqual(incremental.newMessages.map(\.id), ["assistant-2"])
        XCTAssertEqual(incremental.newMessages.first?.textContent, "搞定 ✅")

        let info = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: tempDirectory.path,
            explicitFilePath: indexURL.path
        )
        XCTAssertEqual(info.firstUserMessage, "先记住我的偏好")
        XCTAssertEqual(info.lastMessage, "搞定 ✅")
        XCTAssertEqual(info.lastMessageRole, "assistant")
    }

    func testConversationParserCodeBuddyHistoryKeepsOnlyUserQueryText() async throws {
        let sessionId = "workbuddy-query-\(UUID().uuidString)"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyDirectory = tempDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
        let messagesDirectory = historyDirectory.appendingPathComponent("messages", isDirectory: true)
        let indexURL = historyDirectory.appendingPathComponent("index.json")

        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let wrappedUserMessage = """
        <user_info> OS Version: darwin Shell: Zsh Workspace Folder: /Users/ping-island/WorkBuddy/20260412230308 </user_info>
        <artifact_directory_path> Artifact Directory Path: /Users/ping-island/Library/Application Support/WorkBuddy/User/globalStorage/tencent-cloud.coding-copilot/brain/example </artifact_directory_path>
        <project_context> <project_layout> /Users/ping-island/WorkBuddy/20260412230308/ </project_layout> </project_context>
        <additional_data> current_time: Sunday, April 12, 2026，23:31 </additional_data>
        <system_reminder> <working_memory_reminder> reminder </working_memory_reminder> </system_reminder>
        <user_query> hi </user_query>
        """

        let userPayload: [String: Any] = [
            "id": "user-1",
            "role": "user",
            "message": String(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "role": "user",
                        "content": wrappedUserMessage
                    ],
                    options: [.sortedKeys]
                ),
                encoding: .utf8
            ) ?? ""
        ]
        let assistantPayload: [String: Any] = [
            "id": "assistant-1",
            "role": "assistant",
            "message": String(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "Hello there"]
                        ]
                    ],
                    options: [.sortedKeys]
                ),
                encoding: .utf8
            ) ?? ""
        ]
        try JSONSerialization.data(withJSONObject: userPayload, options: [.sortedKeys, .prettyPrinted])
            .write(to: messagesDirectory.appendingPathComponent("user-1.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: assistantPayload, options: [.sortedKeys, .prettyPrinted])
            .write(to: messagesDirectory.appendingPathComponent("assistant-1.json"), options: .atomic)

        let indexPayload: [String: Any] = [
            "messages": [
                ["id": "user-1", "role": "user", "type": "text", "isComplete": true],
                ["id": "assistant-1", "role": "assistant", "type": "text", "isComplete": true]
            ],
            "requests": [[
                "id": "request-1",
                "messages": ["user-1", "assistant-1"],
                "startedAt": 1_776_006_100_000 as Int
            ]]
        ]
        try JSONSerialization.data(withJSONObject: indexPayload, options: [.sortedKeys, .prettyPrinted])
            .write(to: indexURL, options: .atomic)

        await ConversationParser.shared.resetState(for: sessionId)
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: tempDirectory.path,
            explicitFilePath: indexURL.path
        )
        let info = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: tempDirectory.path,
            explicitFilePath: indexURL.path
        )

        XCTAssertEqual(messages.first?.textContent, "hi")
        XCTAssertEqual(info.firstUserMessage, "hi")
        XCTAssertEqual(info.lastMessage, "Hello there")
    }

    func testConversationParserCodeBuddyHistoryFormatsQuestionAnswerPayload() async throws {
        let sessionId = "workbuddy-question-answer-\(UUID().uuidString)"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyDirectory = tempDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
        let messagesDirectory = historyDirectory.appendingPathComponent("messages", isDirectory: true)
        let indexURL = historyDirectory.appendingPathComponent("index.json")

        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let wrappedUserMessage = """
        <user_query>
        <question_answer>
        <questions>
        <question_item id="q5">
        <question>你对项目有什么具体想法或需求？（可选）</question>
        <answers>
        还没想好，需要你推荐
        </answers>
        </question_item>
        </questions>
        </question_answer>
        </user_query>
        """

        let userPayload: [String: Any] = [
            "id": "user-1",
            "role": "user",
            "message": String(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "role": "user",
                        "content": wrappedUserMessage
                    ],
                    options: [.sortedKeys]
                ),
                encoding: .utf8
            ) ?? ""
        ]
        let assistantPayload: [String: Any] = [
            "id": "assistant-1",
            "role": "assistant",
            "message": String(
                data: try JSONSerialization.data(
                    withJSONObject: [
                        "role": "assistant",
                        "content": [
                            ["type": "text", "text": "收到，我来给你一些建议。"]
                        ]
                    ],
                    options: [.sortedKeys]
                ),
                encoding: .utf8
            ) ?? ""
        ]

        try JSONSerialization.data(withJSONObject: userPayload, options: [.sortedKeys, .prettyPrinted])
            .write(to: messagesDirectory.appendingPathComponent("user-1.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: assistantPayload, options: [.sortedKeys, .prettyPrinted])
            .write(to: messagesDirectory.appendingPathComponent("assistant-1.json"), options: .atomic)

        let indexPayload: [String: Any] = [
            "messages": [
                ["id": "user-1", "role": "user", "type": "text", "isComplete": true],
                ["id": "assistant-1", "role": "assistant", "type": "text", "isComplete": true]
            ],
            "requests": [[
                "id": "request-1",
                "messages": ["user-1", "assistant-1"],
                "startedAt": 1_776_006_100_000 as Int
            ]]
        ]
        try JSONSerialization.data(withJSONObject: indexPayload, options: [.sortedKeys, .prettyPrinted])
            .write(to: indexURL, options: .atomic)

        await ConversationParser.shared.resetState(for: sessionId)
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: tempDirectory.path,
            explicitFilePath: indexURL.path
        )

        XCTAssertEqual(
            messages.first?.textContent,
            "问题：你对项目有什么具体想法或需求？（可选） 回答：还没想好，需要你推荐"
        )
    }

    func testGhosttySelectionScriptPrefersStableTerminalIdentifier() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: "65a2028f-a93c-48e0-b46a-3f4c20c94b81",
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set targetTerminalID to \"65A2028F-A93C-48E0-B46A-3F4C20C94B81\""))
        XCTAssertTrue(script.contains("set targetTerminal to first terminal whose id is targetTerminalID"))
        XCTAssertTrue(script.contains("focus targetTerminal"))

        let identifierIndex = try! XCTUnwrap(lines.firstIndex(of: "set targetTerminalID to \"65A2028F-A93C-48E0-B46A-3F4C20C94B81\""))
        let workspaceIndex = try! XCTUnwrap(lines.firstIndex(of: "set targetPath to \"/tmp/demo\""))
        XCTAssertLessThan(identifierIndex, workspaceIndex)
    }

    func testGhosttySelectionScriptFallsBackToWorkspaceMatchingWithoutIdentifier() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: nil,
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertFalse(script.contains("targetTerminalID"))
        XCTAssertTrue(script.contains("set targetPath to \"/tmp/demo\""))
        XCTAssertTrue(script.contains("focus (item 1 of exactMatches)"))
    }

    func testGhosttySelectionScriptIgnoresNonUUIDTerminalIdentifier() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: "ghostty-terminal-1",
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertFalse(script.contains("targetTerminalID"))
        XCTAssertTrue(script.contains("set targetPath to \"/tmp/demo\""))
    }
}
