import XCTest
@testable import Ping_Island

final class SessionStoreCodexInterventionTests: XCTestCase {
    func testHistoricalCodexThreadListCreatedAtIsPreserved() async throws {
        let sessionId = "codex-historical-thread-\(UUID().uuidString)"
        let store = SessionStore.shared
        let createdTimestamp: TimeInterval = 1_700_000_000
        let updatedTimestamp: TimeInterval = 1_700_003_600
        let lifecycleDates = CodexAppServerMonitor.threadLifecycleDates(from: [
            "id": sessionId,
            "createdAt": createdTimestamp,
            "updatedAt": updatedTimestamp
        ])
        let createdAt = try XCTUnwrap(lifecycleDates.createdAt)
        let updatedAt = try XCTUnwrap(lifecycleDates.updatedAt)

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Historical thread",
            preview: "Earlier assistant reply",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            createdAt: createdAt,
            activityAt: updatedAt
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.createdAt, createdAt)
        XCTAssertEqual(session?.lastActivity, updatedAt)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

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

    func testCodexRolloutRequestUserInputIdleRefreshKeepsQuestionVisible() async {
        let sessionId = "codex-rollout-question-\(UUID().uuidString)"
        let store = SessionStore.shared

        let intervention = SessionIntervention(
            id: "call_question_1",
            kind: .question,
            title: "Codex Needs Input",
            message: "What kind of question do you want me to ask?",
            options: [],
            questions: [
                SessionInterventionQuestion(
                    id: "focus",
                    header: "Focus",
                    prompt: "What kind of question do you want me to ask?",
                    detail: nil,
                    options: [
                        SessionInterventionOption(
                            id: "Planning",
                            title: "Planning",
                            detail: "Ask about implementation planning."
                        )
                    ],
                    allowsMultiple: false,
                    allowsOther: true,
                    isSecret: false
                )
            ],
            supportsSessionScope: false,
            metadata: [
                "source": "codex_rollout_request_user_input",
                "responseMode": "external_only",
                "toolUseId": "call_question_1"
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
            preview: "ask me a question with tool",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: Date().addingTimeInterval(10)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.id, "call_question_1")
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_rollout_request_user_input")
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexIdleSnapshotDoesNotClearExistingExternalQuestion() async {
        let sessionId = "codex-existing-question-\(UUID().uuidString)"
        let store = SessionStore.shared
        let startedAt = Date()
        let intervention = SessionIntervention(
            id: "call_question_1",
            kind: .question,
            title: "Codex Needs Input",
            message: "Pick an implementation path.",
            options: [],
            questions: [
                SessionInterventionQuestion(
                    id: "path",
                    header: "Path",
                    prompt: "Pick an implementation path.",
                    detail: nil,
                    options: [
                        SessionInterventionOption(id: "minimal", title: "Minimal", detail: nil)
                    ],
                    allowsMultiple: false,
                    allowsOther: true,
                    isSecret: false
                )
            ],
            supportsSessionScope: false,
            metadata: [
                "source": "codex_rollout_request_user_input",
                "responseMode": "external_only",
                "toolUseId": "call_question_1"
            ]
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: intervention.message,
            cwd: "/tmp/project",
            phase: .waitingForInput,
            intervention: intervention,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex")
        )

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: "Previous assistant reply",
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
                intervention: nil,
                createdAt: startedAt,
                updatedAt: startedAt.addingTimeInterval(5),
                phase: .idle,
                historyItems: [
                    ChatHistoryItem(id: "assistant", type: .assistant("Previous assistant reply"), timestamp: startedAt)
                ],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: "Previous assistant reply",
                    lastMessageRole: "assistant",
                    lastToolName: nil,
                    firstUserMessage: "start",
                    lastUserMessageDate: startedAt
                ),
                latestTurnId: "turn-1",
                latestResponseText: "Previous assistant reply",
                latestResponsePhase: "final",
                latestUserText: "start"
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.id, "call_question_1")
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertFalse(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexAppServerIdleRefreshDoesNotDowngradeActiveSession() async {
        let sessionId = "codex-active-refresh-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Implement feature",
            preview: "Working",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex")
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Implement feature",
            preview: "Done with current step",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            activityAt: Date().addingTimeInterval(10)
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.previewText, "Done with current step")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexFinalIdleSnapshotMarksSessionCompletedReady() async {
        let sessionId = "codex-final-idle-\(UUID().uuidString)"
        let store = SessionStore.shared
        let startedAt = Date()
        let completedAt = startedAt.addingTimeInterval(12)

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: "Working",
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
                intervention: nil,
                createdAt: startedAt,
                updatedAt: startedAt,
                phase: .processing,
                historyItems: [
                    ChatHistoryItem(id: "user", type: .user("fix sounds"), timestamp: startedAt)
                ],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: "fix sounds",
                    lastMessageRole: "user",
                    lastToolName: nil,
                    firstUserMessage: "fix sounds",
                    lastUserMessageDate: startedAt
                ),
                latestTurnId: "turn-1",
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "fix sounds"
            )
        )

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: "Done",
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
                intervention: nil,
                createdAt: startedAt,
                updatedAt: completedAt,
                phase: .idle,
                historyItems: [
                    ChatHistoryItem(id: "user", type: .user("fix sounds"), timestamp: startedAt),
                    ChatHistoryItem(id: "assistant", type: .assistant("Done"), timestamp: completedAt)
                ],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: "Done",
                    lastMessageRole: "assistant",
                    lastToolName: nil,
                    firstUserMessage: "fix sounds",
                    lastUserMessageDate: startedAt
                ),
                latestTurnId: "turn-1",
                latestResponseText: "Done",
                latestResponsePhase: "final",
                latestUserText: "fix sounds"
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.createdAt, startedAt)
        XCTAssertNil(session?.intervention)
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexRequestUserInputResponsePayloadMatchesAppServerShape() throws {
        let payload = CodexAppServerMonitor.requestUserInputResponsePayload(answers: [
            "focus": ["Planning"],
            "details": ["A", "B"]
        ])
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8)

        XCTAssertEqual(
            json,
            #"{"answers":{"details":{"answers":["A","B"]},"focus":{"answers":["Planning"]}}}"#
        )
    }

    func testCodexRolloutQuestionCallIdFallsBackToInterventionId() {
        let intervention = SessionIntervention(
            id: "call_from_id",
            kind: .question,
            title: "Codex Needs Input",
            message: "Need input",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "source": "codex_rollout_request_user_input",
                "responseMode": "external_only"
            ]
        )

        XCTAssertTrue(SessionMonitor.shouldSubmitCodexRolloutUserInput(intervention))
        XCTAssertEqual(SessionMonitor.codexRolloutUserInputCallId(for: intervention), "call_from_id")
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

    func testCodexTurnAbortAllowsRunningThreadToReturnIdle() async {
        let sessionId = "codex-aborted-tool-\(UUID().uuidString)"
        let store = SessionStore.shared
        let startedAt = Date()
        let runningTool = ChatHistoryItem(
            id: "tool-1",
            type: .toolCall(ToolCallItem(
                name: "shell",
                input: ["command": "xcodebuild test"],
                status: .running,
                result: nil,
                structuredResult: nil,
                subagentTools: []
            )),
            timestamp: startedAt
        )

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: "Running tests",
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
                intervention: nil,
                createdAt: startedAt,
                updatedAt: startedAt,
                phase: .processing,
                historyItems: [runningTool],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "run tests",
                    lastUserMessageDate: startedAt
                ),
                latestTurnId: "turn-1",
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "run tests"
            )
        )

        var interruptedTool = runningTool
        if case .toolCall(var tool) = runningTool.type {
            tool.status = .interrupted
            interruptedTool = ChatHistoryItem(id: runningTool.id, type: .toolCall(tool), timestamp: runningTool.timestamp)
        }

        await store.syncCodexThreadSnapshot(
            CodexThreadSnapshot(
                threadId: sessionId,
                name: "Codex",
                preview: "Interrupted",
                cwd: "/tmp/project",
                clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
                intervention: nil,
                createdAt: startedAt,
                updatedAt: startedAt.addingTimeInterval(30),
                phase: .idle,
                historyItems: [interruptedTool],
                conversationInfo: ConversationInfo(
                    summary: "Codex",
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "run tests",
                    lastUserMessageDate: startedAt
                ),
                latestTurnId: "turn-1",
                latestResponseText: nil,
                latestResponsePhase: nil,
                latestUserText: "run tests",
                isTurnInterrupted: true
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        guard case .toolCall(let tool) = session?.chatItems.last?.type else {
            return XCTFail("Expected interrupted tool call")
        }
        XCTAssertEqual(tool.status, .interrupted)

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

    func testCodexHookPermissionInterventionRestoresApprovalPhaseDuringAppServerRefresh() async {
        let sessionId = "codex-hook-degraded-\(UUID().uuidString)"
        let store = SessionStore.shared
        let intervention = SessionIntervention(
            id: "call-date-degraded",
            kind: .approval,
            title: "Approve Command",
            message: "date",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "source": "codex_hook_permission",
                "toolName": "Bash"
            ]
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Run date",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: intervention,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId)
        )

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Run date",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: Date().addingTimeInterval(5)
        )

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)
        XCTAssertEqual(session?.activePermission?.toolUseId, "call-date-degraded")
        XCTAssertEqual(session?.activePermission?.toolName, "Bash")
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_hook_permission")
        XCTAssertEqual(session?.ingress, .hookBridge)
        XCTAssertTrue(session?.needsApprovalResponse ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexBridgePermissionInterventionKeepsResolvedToolUseIdAcrossRefresh() async {
        let sessionId = "codex-bridge-approval-\(UUID().uuidString)"
        let store = SessionStore.shared
        let bridgeIntervention = SessionIntervention(
            id: "bridge-intervention-id",
            kind: .approval,
            title: "Codex needs approval",
            message: "Bash",
            options: [
                SessionInterventionOption(id: "approve", title: "Allow Once", detail: nil),
                SessionInterventionOption(id: "approveForSession", title: "Allow for Session", detail: nil),
                SessionInterventionOption(id: "deny", title: "Deny", detail: nil)
            ],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )

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
                "command": AnyCodable("open ."),
                "description": AnyCodable("Open the project in Finder.")
            ],
            toolUseId: "call-open-project",
            notificationType: nil,
            message: nil,
            bridgeIntervention: bridgeIntervention
        )))

        var session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.id, "bridge-intervention-id")
        XCTAssertEqual(session?.intervention?.message, "open .")
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_hook_permission")
        XCTAssertEqual(session?.intervention?.metadata["toolUseId"], "call-open-project")
        XCTAssertEqual(session?.intervention?.metadata["tool_input_json"]?.contains("\"command\":\"open .\""), true)

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Codex",
            preview: "Open project",
            cwd: "/tmp/project",
            phase: .processing,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            activityAt: Date().addingTimeInterval(5)
        )

        session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)
        XCTAssertEqual(session?.activePermission?.toolUseId, "call-open-project")
        XCTAssertEqual(session?.activePermission?.toolName, "Bash")
        XCTAssertEqual(session?.intervention?.id, "bridge-intervention-id")
        XCTAssertEqual(session?.intervention?.message, "open .")
        XCTAssertEqual(session?.intervention?.metadata["source"], "codex_hook_permission")
        XCTAssertEqual(session?.ingress, .hookBridge)

        await store.process(.permissionApproved(sessionId: sessionId, toolUseId: "call-open-project"))

        session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

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
