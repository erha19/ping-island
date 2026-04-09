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

        XCTAssertEqual(session.clientDisplayName, "Codex")
        XCTAssertEqual(session.interactionDisplayName, "Ghostty")
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

    func testQoderWorkDoesNotShowQoderTerminalBadge() {
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
        XCTAssertEqual(normalized.ideHostProfile?.id, "qoderwork-extension")
        XCTAssertTrue(normalized.isHostedInIDE)
        XCTAssertNil(normalized.ideHostBadgeLabel(for: .claude))
    }

    func testQoderWorkExtensionProfileMatchesBundleAndName() {
        let bundleProfile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: "com.qoder.work",
            appName: "QoderWork"
        )
        let nameOnlyProfile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: nil,
            appName: "QoderWork"
        )

        XCTAssertEqual(bundleProfile?.id, "qoderwork-extension")
        XCTAssertEqual(bundleProfile?.uriScheme, "qoder-work")
        XCTAssertEqual(nameOnlyProfile?.id, "qoderwork-extension")
    }

    func testQoderWorkExtensionProfileStaysHiddenFromSettings() {
        let profile = ClientProfileRegistry.ideExtensionProfile(id: "qoderwork-extension")

        XCTAssertEqual(profile?.id, "qoderwork-extension")
        XCTAssertEqual(profile?.showsInSettings, false)
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
}
