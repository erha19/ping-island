import XCTest
@testable import Ping_Island

final class ClaudeAskUserQuestionSessionTests: XCTestCase {
    func testPreToolUseQuestionImmediatelyEntersWaitingForInput() async {
        let sessionId = "claude-question-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeQuestionEvent(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.options.map(\.title), ["会话层", "UI 层"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testDuplicatePermissionRequestKeepsClaudeQuestionInWaitingForInput() async {
        let sessionId = "claude-ask-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeQuestionEvent(sessionId: sessionId)))
        await store.process(.hookReceived(makeClaudePermissionRequest(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertNil(session?.activePermission)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testDuplicatePermissionRequestDoesNotRestoreApprovalAfterAnswer() async {
        let sessionId = "claude-answer-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeQuestionEvent(sessionId: sessionId)))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["project": ["会话层"]]
            )
        )
        await store.process(.hookReceived(makeClaudePermissionRequest(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)
        XCTAssertNil(session?.activePermission)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderWorkPermissionRequestStaysNotifyOnly() async {
        let sessionId = "qoderwork-permission-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderPromptSubmitEvent(
            sessionId: sessionId,
            profileID: "qoderwork",
            name: "QoderWork",
            bundleIdentifier: "com.qoder.work"
        )))
        await store.process(.hookReceived(makeQoderWorkPermissionRequest(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderIDEPermissionRequestQuestionDoesNotCreateApproval() async {
        let sessionId = "qoderide-permission-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderPromptSubmitEvent(
            sessionId: sessionId,
            profileID: "qoder",
            name: "Qoder",
            bundleIdentifier: "com.qoder.ide"
        )))
        let permissionRequest = makeQoderIDEPermissionRequest(sessionId: sessionId)
        XCTAssertFalse(permissionRequest.expectsResponse)

        await store.process(.hookReceived(permissionRequest))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.metadata["responseMode"], "external_only")
        XCTAssertFalse(session?.intervention?.supportsInlineResponse ?? true)
        XCTAssertNil(session?.activePermission)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)
        XCTAssertTrue(session?.needsQuestionResponse ?? false)
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderIDEPreToolUseQuestionDoesNotExpectResponse() async {
        let sessionId = "qoderide-pretool-\(UUID().uuidString)"
        let event = makeQoderIDEPreToolUseQuestion(sessionId: sessionId)

        XCTAssertFalse(event.expectsResponse)
        XCTAssertEqual(event.sessionPhase, .waitingForInput)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertEqual(event.intervention?.metadata["responseMode"], "external_only")
        XCTAssertFalse(event.intervention?.supportsInlineResponse ?? true)
    }

    func testQoderIDEQuestionInterventionIdDoesNotRefreshAcrossHookLifecycle() async {
        let sessionId = "qoderide-duplicate-\(UUID().uuidString)"
        let preToolUse = makeQoderIDEPreToolUseQuestion(sessionId: sessionId)
        let permissionRequest = makeQoderIDEPermissionRequest(
            sessionId: sessionId,
            toolUseId: "permission-\(UUID().uuidString)"
        )

        XCTAssertEqual(preToolUse.intervention?.id, permissionRequest.intervention?.id)

        let store = SessionStore.shared
        await store.process(.hookReceived(preToolUse))
        let firstInterventionId = await store.session(for: sessionId)?.intervention?.id
        await store.process(.hookReceived(permissionRequest))
        let secondInterventionId = await store.session(for: sessionId)?.intervention?.id

        XCTAssertEqual(firstInterventionId, secondInterventionId)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderIDEPostToolUseAnsweredQuestionClearsExternalNotification() async {
        let sessionId = "qoderide-answer-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderIDEPreToolUseQuestion(sessionId: sessionId)))
        var session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.hookReceived(makeQoderIDEPostToolUseAnsweredQuestion(sessionId: sessionId)))

        session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertFalse(session?.needsQuestionResponse ?? true)
        XCTAssertEqual(session?.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderCLIPostToolUseDoesNotImmediatelyClearPendingQuestion() async {
        let sessionId = "qoder-cli-post-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderCLIQuestionEvent(sessionId: sessionId)))
        await store.process(.hookReceived(makeQoderCLIPostToolUseEvent(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.options.map(\.title), ["Strict", "Balanced"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testHistoryLoadedQuestionToolSynthesizesClaudeIntervention() async {
        let sessionId = "claude-history-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudePromptSubmitEvent(sessionId: sessionId)))
        await store.process(
            .historyLoaded(
                sessionId: sessionId,
                messages: [
                    ChatMessage(
                        id: "assistant-tool-message",
                        role: .assistant,
                        timestamp: Date(),
                        content: [
                            .toolUse(
                                ToolUseBlock(
                                    id: "toolu_\(sessionId)",
                                    name: "AskUserQuestion",
                                    input: [
                                        "questions": """
                                        [
                                          {
                                            "id":"project",
                                            "header":"方向",
                                            "question":"你想先处理哪个模块？",
                                            "options":[
                                              {"label":"会话层"},
                                              {"label":"UI 层"}
                                            ]
                                          }
                                        ]
                                        """
                                    ]
                                )
                            )
                        ]
                    )
                ],
                completedTools: [],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "使用工具问我一个问题",
                    lastUserMessageDate: Date()
                )
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.prompt, "你想先处理哪个模块？")
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.options.map(\.title), ["会话层", "UI 层"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testRemoteBridgeHistoryLoadedQuestionToolDoesNotSynthesizesClaudeTranscriptIntervention() async {
        let sessionId = "claude-remote-history-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeRemoteClaudePromptSubmitEvent(sessionId: sessionId)))
        await store.process(
            .historyLoaded(
                sessionId: sessionId,
                messages: [
                    ChatMessage(
                        id: "assistant-tool-message",
                        role: .assistant,
                        timestamp: Date(),
                        content: [
                            .toolUse(
                                ToolUseBlock(
                                    id: "toolu_\(sessionId)",
                                    name: "AskUserQuestion",
                                    input: [
                                        "questions": """
                                        [
                                          {
                                            "id":"project",
                                            "header":"方向",
                                            "question":"你想先处理哪个模块？",
                                            "options":[
                                              {"label":"会话层"},
                                              {"label":"UI 层"}
                                            ]
                                          }
                                        ]
                                        """
                                    ]
                                )
                            )
                        ]
                    )
                ],
                completedTools: [],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "使用工具问我一个问题",
                    lastUserMessageDate: Date()
                )
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertNotEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func makeClaudeQuestionEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "project",
                        "header": "方向",
                        "question": "你想先处理哪个模块？",
                        "options": [
                            ["label": "会话层"],
                            ["label": "UI 层"]
                        ]
                    ]
                ])
            ],
            toolUseId: "toolu_\(sessionId)",
            notificationType: nil,
            message: nil
        )
    }

    private func makeClaudePermissionRequest(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "project",
                        "header": "方向",
                        "question": "你想先处理哪个模块？",
                        "options": [
                            ["label": "会话层"],
                            ["label": "UI 层"]
                        ]
                    ]
                ])
            ],
            toolUseId: "toolu_\(sessionId)",
            notificationType: nil,
            message: nil
        )
    }

    private func makeQoderWorkPermissionRequest(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "主题",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    private func makeQoderIDEPermissionRequest(sessionId: String, toolUseId: String? = nil) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder",
                name: "Qoder",
                bundleIdentifier: "com.qoder.ide"
            ),
            pid: nil,
            tty: nil,
            tool: "ask_user_question",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "主题",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    private func makeQoderIDEPreToolUseQuestion(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder",
                name: "Qoder",
                bundleIdentifier: "com.qoder.ide"
            ),
            pid: nil,
            tty: nil,
            tool: "ask_user_question",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "主题",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    private func makeQoderIDEPostToolUseAnsweredQuestion(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PostToolUse",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder",
                name: "Qoder",
                bundleIdentifier: "com.qoder.ide"
            ),
            pid: nil,
            tty: nil,
            tool: "ask_user_question",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "主题",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: "User has answered your questions."
        )
    }

    private func makeQoderCLIQuestionEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "permission",
                        "header": "Permission Mode",
                        "question": "Which permission mode would you prefer?",
                        "options": [
                            ["label": "Strict"],
                            ["label": "Balanced"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_\(sessionId)",
            notificationType: nil,
            message: nil
        )
    }

    private func makeQoderCLIPostToolUseEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PostToolUse",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "permission",
                        "header": "Permission Mode",
                        "question": "Which permission mode would you prefer?",
                        "options": [
                            ["label": "Strict"],
                            ["label": "Balanced"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_\(sessionId)",
            notificationType: nil,
            message: "User dismissed AskUserQuestion dialog without answering."
        )
    }

    private func makeClaudePromptSubmitEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode",
                sessionFilePath: "/tmp/\(sessionId).jsonl"
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "使用工具问我一个问题"
        )
    }

    private func makeRemoteClaudePromptSubmitEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode",
                remoteHost: "remote.example",
                sessionFilePath: "/tmp/\(sessionId).jsonl"
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "使用工具问我一个问题",
            ingress: .remoteBridge
        )
    }

    private func makeQoderPromptSubmitEvent(
        sessionId: String,
        profileID: String,
        name: String,
        bundleIdentifier: String
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: profileID,
                name: name,
                bundleIdentifier: bundleIdentifier
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "使用工具问我一个问题"
        )
    }
}
