import XCTest
@testable import Ping_Island

final class QwenCodeIntegrationTests: XCTestCase {
    func testConcurrentQwenSessionsInSameWorkspaceRemainIndependent() async {
        let firstSessionId = "qwen-concurrent-first-\(UUID().uuidString)"
        let secondSessionId = "qwen-concurrent-second-\(UUID().uuidString)"
        let workspace = "/tmp/qwen-concurrent-workspace-\(UUID().uuidString)"
        let store = SessionStore.shared
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        func promptEvent(sessionId: String, message: String) -> HookEvent {
            HookEvent(
                sessionId: sessionId,
                cwd: workspace,
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: clientInfo,
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: message
            )
        }

        await store.process(.hookReceived(promptEvent(
            sessionId: firstSessionId,
            message: "First concurrent request"
        )))
        await store.process(.hookReceived(promptEvent(
            sessionId: secondSessionId,
            message: "Second concurrent request"
        )))

        let firstSession = await store.session(for: firstSessionId)
        let secondSession = await store.session(for: secondSessionId)
        XCTAssertNotNil(firstSession)
        XCTAssertNotNil(secondSession)
        XCTAssertEqual(firstSession?.latestHookMessage, "First concurrent request")
        XCTAssertEqual(secondSession?.latestHookMessage, "Second concurrent request")

        await store.process(.sessionArchived(sessionId: firstSessionId))
        await store.process(.sessionArchived(sessionId: secondSessionId))
    }

    func testQwenStopBridgeMessageFallsBackToLastAssistantMessage() {
        XCTAssertEqual(
            HookSocketServer.resolvedBridgeMessage(
                eventType: "Stop",
                metadata: [
                    "message": "Qwen Code needs your permission to run Bash",
                    "last_assistant_message": "Done. I updated the files and left notes in the summary."
                ],
                preview: nil
            ),
            "Done. I updated the files and left notes in the summary."
        )
    }

    func testQwenAskUserQuestionPermissionRequestSupportsInlineQuestionResponse() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        let event = HookEvent(
            sessionId: "qwen-session",
            cwd: "/tmp/qwen-project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "你想做什么项目？",
                        "header": "项目类型",
                        "options": [
                            ["label": "网站开发"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: "Qwen Code needs your permission to use ask_user_question"
        )

        XCTAssertTrue(event.isAskUserQuestionRequest)
        XCTAssertTrue(event.expectsResponse)
        XCTAssertEqual(event.determinePhase(), .waitingForInput)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertTrue(event.intervention?.supportsInlineResponse ?? false)
        XCTAssertNil(event.intervention?.metadata["responseMode"])
        XCTAssertTrue(event.intervention?.message.contains("提交后会继续执行") ?? false)
    }

    func testQwenCodeManagedProfileUsesOfficialHooksSettings() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "qwen-code-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Qwen Code")
        XCTAssertEqual(profile?.brand, .qwen)
        XCTAssertEqual(profile?.logoAssetName, "QwenLogo")
        XCTAssertEqual(profile?.primaryConfigurationURL.path, NSHomeDirectory() + "/.qwen/settings.json")
        XCTAssertTrue(profile?.alwaysVisibleInSettings == true)
    }

    func testQwenCodeRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: "qwen-code",
            explicitName: "Qwen Code",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks",
            processName: nil
        )

        XCTAssertEqual(profile?.id, "qwen-code")
        XCTAssertEqual(profile?.brand, .qwen)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        XCTAssertEqual(clientInfo.brand, .qwen)
        XCTAssertTrue(clientInfo.isQwenCodeClient)
        XCTAssertTrue(clientInfo.prefersHookMessageAsLastMessageFallback)
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .claude), .qwen)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .claude), .qwen)
        XCTAssertEqual(MascotClient.qwen.subtitle, "Qwen Code 官方 hooks 与薄荷围巾卡皮巴拉")
        XCTAssertEqual(MascotKind.qwen.subtitle, "薄荷围巾卡皮巴拉")
    }

    func testQwenCodeLastMessageFallsBackToHookMessageForPopupPreview() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )
        let session = SessionState(
            sessionId: "qwen-stop",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: clientInfo,
            latestHookMessage: "Qwen Code finished the task and is ready for your next prompt.",
            phase: .ended
        )

        XCTAssertEqual(
            session.lastMessage,
            "Qwen Code finished the task and is ready for your next prompt."
        )
    }

    func testQwenPermissionPromptDoesNotOverrideAssistantHookMessage() async {
        let sessionId = "qwen-hook-message-\(UUID().uuidString)"
        let store = SessionStore.shared
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "Notification",
            status: "notification",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: "assistant_message",
            message: "这是模型最后一句真正的回复。"
        )))

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("ls")],
            toolUseId: "qwen-permission-1",
            notificationType: "permission_prompt",
            message: "Qwen Code needs your permission to run Bash"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.latestHookMessage, "这是模型最后一句真正的回复。")
        XCTAssertEqual(session?.lastMessage, "这是模型最后一句真正的回复。")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQwenPermissionPromptNotificationDoesNotClearQuestionIntervention() async {
        let sessionId = "qwen-question-\(UUID().uuidString)"
        let store = SessionStore.shared
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "你想学哪种编程语言？",
                        "header": "编程语言",
                        "options": [
                            ["label": "Python"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: "ask_user_question"
        )))

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "Notification",
            status: "notification",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: "permission_prompt",
            message: "Qwen Code needs your permission to use ask_user_question"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertTrue(session?.intervention?.supportsInlineResponse ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    // MARK: - Notification permission_prompt as actionable approval

    func testQwenNotificationPermissionPromptCreatesApprovalState() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        let event = HookEvent(
            sessionId: "qwen-notification-approval",
            cwd: "/tmp/qwen-project",
            event: "Notification",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: "permission_prompt",
            message: "Qwen Code wants to run Bash: ls"
        )

        XCTAssertTrue(event.expectsResponse)
        let phase = event.determinePhase()
        if case .waitingForApproval(let ctx) = phase {
            XCTAssertEqual(ctx.toolName, "Permission")
        } else {
            XCTFail("Expected waitingForApproval but got \(phase)")
        }
    }

    func testQwenAnsweredAskUserQuestionPreToolUseDoesNotRequestAnotherResponse() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        let event = HookEvent(
            sessionId: "qwen-answered-question",
            cwd: "/tmp/qwen-project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "你最喜欢哪种编程语言？",
                        "header": "编程语言",
                        "options": [
                            ["label": "Python"]
                        ]
                    ]
                ]),
                "answers": AnyCodable([
                    "0": "Python"
                ])
            ],
            toolUseId: "toolu_qwen_answered",
            notificationType: nil,
            message: "ask_user_question"
        )

        XCTAssertTrue(event.isAnsweredAskUserQuestionEvent)
        XCTAssertFalse(event.isAskUserQuestionRequest)
        XCTAssertFalse(event.expectsResponse)
        XCTAssertEqual(event.determinePhase(), .processing)
        XCTAssertNil(event.intervention)
    }

    func testQwenAnsweredAskUserQuestionPreToolUseDoesNotReopenQuestion() async {
        let sessionId = "qwen-answered-pretool-\(UUID().uuidString)"
        let store = SessionStore.shared
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "tooling",
                        "question": "你想用什么开发工具？",
                        "header": "开发工具",
                        "options": [
                            ["label": "WebStorm"]
                        ]
                    ]
                ])
            ],
            toolUseId: "toolu_qwen_pending",
            notificationType: nil,
            message: "ask_user_question"
        )))

        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["tooling": ["WebStorm"]]
            )
        )

        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "tooling",
                        "question": "你想用什么开发工具？",
                        "header": "开发工具",
                        "options": [
                            ["label": "WebStorm"]
                        ]
                    ]
                ]),
                "answers": AnyCodable([
                    "0": "WebStorm"
                ])
            ],
            toolUseId: "toolu_qwen_answered",
            notificationType: nil,
            message: "ask_user_question"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQwenNotificationPermissionPromptDoesNotOverrideExistingApproval() async {
        let sessionId = "qwen-preserve-approval-\(UUID().uuidString)"
        let store = SessionStore.shared
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        // First: PermissionRequest with real tool info
        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("rm -rf /")],
            toolUseId: "qwen-perm-real",
            notificationType: nil,
            message: "Qwen Code wants to run Bash"
        )))

        // Second: Notification permission_prompt should NOT override
        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "Notification",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: "permission_prompt",
            message: "Permission needed"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval ?? false)
        // The intervention should still be from the PermissionRequest, not the Notification
        if case .waitingForApproval(let ctx) = session?.phase {
            XCTAssertEqual(ctx.toolName, "Bash")
            XCTAssertEqual(ctx.toolUseId, "qwen-perm-real")
        } else {
            XCTFail("Expected waitingForApproval")
        }

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQwenStandaloneNotificationPermissionPromptCreatesApproval() async {
        let sessionId = "qwen-standalone-notif-\(UUID().uuidString)"
        let store = SessionStore.shared
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )

        // Send a UserPromptSubmit first to create the session
        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "Please fix the bug"
        )))

        // Standalone Notification permission_prompt (no prior PermissionRequest)
        await store.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/qwen-project",
            event: "Notification",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: "permission_prompt",
            message: "Qwen Code wants to write to file.txt"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }
}
