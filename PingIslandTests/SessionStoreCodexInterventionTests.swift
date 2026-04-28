import XCTest
@testable import Ping_Island

final class SessionStoreCodexInterventionTests: XCTestCase {
    func testCodexAppServerIdleRefreshDoesNotClearExternalOnlyIntervention() async {
        let sessionId = "codex-external-\(UUID().uuidString)"
        let store = SessionStore.shared

        let intervention = SessionIntervention(
            id: "mcp-pending-omx_state-state_list_active",
            kind: .question,
            title: "MCP Tool Approval Needed",
            message: "Allow the omx_state MCP server to run tool \"state_list_active\"?",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "responseMode": "external_only",
                "source": "rollout_pending_mcp",
                "server": "omx_state",
                "toolName": "state_list_active"
            ]
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: intervention.message,
            cwd: "/tmp/project",
            phase: .waitingForInput,
            intervention: intervention,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex")
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: "删除 LICENSE 文件",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex")
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.title, "MCP Tool Approval Needed")
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerQuestionSurvivesRolloutQuestionRefresh() async {
        let sessionId = "codex-app-question-\(UUID().uuidString)"
        let store = SessionStore.shared
        let appServerIntervention = SessionIntervention(
            id: "jsonrpc-request-1",
            kind: .question,
            title: "Codex Needs Input",
            message: "TodoList 示例的数据要怎么处理？",
            options: [],
            questions: [
                SessionInterventionQuestion(
                    id: "todo_data",
                    header: "Data",
                    prompt: "TodoList 示例的数据要怎么处理？",
                    detail: nil,
                    options: [],
                    allowsMultiple: false,
                    allowsOther: false,
                    isSecret: false
                )
            ],
            supportsSessionScope: false,
            metadata: [
                "turnId": "turn-1",
                "itemId": "item-1"
            ]
        )
        let rolloutIntervention = SessionIntervention(
            id: "call_question_1",
            kind: .question,
            title: "Codex Needs Input",
            message: "TodoList 示例的数据要怎么处理？",
            options: [],
            questions: appServerIntervention.resolvedQuestions,
            supportsSessionScope: false,
            metadata: [
                "source": "codex_rollout_request_user_input",
                "responseMode": "external_only",
                "toolUseId": "call_question_1"
            ]
        )
        let now = Date()

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: appServerIntervention.message,
            cwd: "/tmp/project",
            phase: .waitingForInput,
            intervention: appServerIntervention,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: now
        )

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: rolloutIntervention.message,
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
                intervention: rolloutIntervention,
                createdAt: now,
                updatedAt: now.addingTimeInterval(1),
                phase: .waitingForInput,
                historyItems: [],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: rolloutIntervention.message,
                    lastMessageRole: "assistant",
                    lastToolName: nil,
                    firstUserMessage: "build a TodoList sample",
                    lastUserMessageDate: now
                ),
                latestTurnId: "turn-1",
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "build a TodoList sample"
            ),
            ingress: .hookBridge
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.id, "jsonrpc-request-1")
        XCTAssertEqual(session?.intervention?.metadata["itemId"], "item-1")
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testStaleCodexIdleRefreshDoesNotDowngradeFreshProcessingState() async {
        let sessionId = "codex-stale-idle-\(UUID().uuidString)"
        let store = SessionStore.shared
        let freshActivityAt = Date()

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Following up",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: freshActivityAt
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Old snapshot",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: freshActivityAt.addingTimeInterval(-300)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.lastActivity, freshActivityAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexIdleRefreshDoesNotDowngradeRunningToolThread() async {
        let sessionId = "codex-running-tool-\(UUID().uuidString)"
        let store = SessionStore.shared
        let startedAt = Date()

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: "Running tool",
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
                intervention: nil,
                createdAt: startedAt,
                updatedAt: startedAt,
                phase: .processing,
                historyItems: [
                    ChatHistoryItem(
                        id: "tool-1",
                        type: .toolCall(ToolCallItem(
                            name: "shell",
                            input: ["command": "sleep 120"],
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: startedAt
                    )
                ],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "keep going",
                    lastUserMessageDate: startedAt
                ),
                latestTurnId: "turn-1",
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "keep going"
            )
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Idle heartbeat",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: startedAt.addingTimeInterval(90)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.lastActivity, startedAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexStopWithAssistantReplyLeavesPrimaryListAndFeedsCompletionLane() async {
        let sessionId = "codex-stop-final-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "SessionStart",
            status: "processing",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "work on this",
            ingress: .hookBridge
        )))

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "Stop",
            status: "completed",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "Done and ready to review.",
            ingress: .hookBridge
        )))

        guard let session = await store.session(for: sessionId) else {
            XCTFail("Expected Codex session")
            return
        }
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.lifecycleCompletedAt)
        XCTAssertEqual(session.conversationInfo.lastMessage, "Done and ready to review.")
        XCTAssertEqual(session.conversationInfo.lastMessageRole, "assistant")
        XCTAssertTrue(session.shouldHideFromPrimaryUI)
        XCTAssertTrue(session.isHiddenCompletionNotificationCandidate)
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexStopWithoutAssistantReplyExitsWithoutCompletionNotification() async {
        let sessionId = "codex-stop-no-reply-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "SessionStart",
            status: "processing",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "start",
            ingress: .hookBridge
        )))

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "Stop",
            status: "completed",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: .hookBridge
        )))

        guard let session = await store.session(for: sessionId) else {
            XCTFail("Expected Codex session")
            return
        }
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.lifecycleCompletedAt)
        XCTAssertTrue(session.shouldHideFromPrimaryUI)
        XCTAssertFalse(session.isHiddenCompletionNotificationCandidate)
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(session))

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testWeakCodexRefreshDoesNotReviveCompletedStopUntilFreshInput() async {
        let sessionId = "codex-stop-weak-refresh-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "SessionStart",
            status: "processing",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "start",
            ingress: .hookBridge
        )))
        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "Stop",
            status: "completed",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "All done.",
            ingress: .hookBridge
        )))

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PostToolUse",
            status: "processing",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: nil,
            toolUseId: "tool-old",
            notificationType: nil,
            message: "old tool completed",
            ingress: .hookBridge
        )))

        guard var session = await store.session(for: sessionId) else {
            XCTFail("Expected Codex session")
            return
        }
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.lifecycleCompletedAt)

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: nil,
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI")
        )

        guard let weakRefreshSession = await store.session(for: sessionId) else {
            XCTFail("Expected Codex session after weak app-server refresh")
            return
        }
        session = weakRefreshSession
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.lifecycleCompletedAt)

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "new prompt",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            allowsCompletedSessionResume: true
        )

        guard let resumedSession = await store.session(for: sessionId) else {
            XCTFail("Expected Codex session after fresh input")
            return
        }
        session = resumedSession
        XCTAssertEqual(session.phase, .processing)
        XCTAssertNil(session.lifecycleCompletedAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexHookPermissionRequestSurvivesAppServerRefresh() async {
        let sessionId = "codex-hook-approval-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("date"),
                "description": AnyCodable("Show the current time.")
            ],
            toolUseId: "call-date-1",
            notificationType: nil,
            message: nil
        )))

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: nil,
            preview: "Show the current time.",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: Date().addingTimeInterval(5)
        )

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)
        XCTAssertEqual(session?.activePermission?.toolUseId, "call-date-1")
        XCTAssertEqual(session?.activePermission?.toolName, "Bash")
        XCTAssertEqual(session?.intervention?.kind, .approval)
        XCTAssertEqual(session?.intervention?.title, "Approve Command")
        XCTAssertEqual(session?.intervention?.message, "date")
        XCTAssertEqual(session?.intervention?.supportsSessionScope, false)
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_hook_permission")
        XCTAssertEqual(session?.ingress, .hookBridge)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexHookPermissionApprovalClearsInterventionImmediately() async {
        let sessionId = "codex-hook-approved-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("curl -I https://example.com"),
                "description": AnyCodable("Allow a test HEAD request.")
            ],
            toolUseId: "call-curl-1",
            notificationType: nil,
            message: nil
        )))

        var session = await store.session(for: sessionId)
        XCTAssertTrue(session?.needsApprovalResponse ?? false)
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_hook_permission")

        await store.process(.permissionApproved(sessionId: sessionId, toolUseId: "call-curl-1"))

        session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexHookPermissionDenialClearsInterventionImmediately() async {
        let sessionId = "codex-hook-denied-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI"),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("curl -I https://example.com")],
            toolUseId: "call-curl-deny",
            notificationType: nil,
            message: nil
        )))

        await store.process(
            .permissionDenied(sessionId: sessionId, toolUseId: "call-curl-deny", reason: "No network")
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }
}
