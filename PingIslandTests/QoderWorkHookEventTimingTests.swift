import XCTest
@testable import Ping_Island

final class QoderWorkHookEventTimingTests: XCTestCase {
    func testQoderWorkPreToolUseQuestionSurfacesIntervention() {
        let event = HookEvent(
            sessionId: "qoderwork-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
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
                        "header": "技能",
                        "question": "你最想了解哪个功能？",
                        "options": [
                            ["label": "MCP 工具集成"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_123",
            notificationType: nil,
            message: nil
        )

        XCTAssertTrue(event.isAskUserQuestionRequest)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertEqual(event.intervention?.id, "call_123")
        XCTAssertFalse(event.intervention?.supportsInlineResponse ?? true)
        XCTAssertEqual(event.intervention?.metadata["responseMode"], "external_only")
        XCTAssertTrue(event.intervention?.message.contains("暂不支持直接提交") ?? false)
        XCTAssertEqual(event.determinePhase(), .waitingForInput)
    }

    func testQoderWorkPermissionRequestQuestionReusesStableInterventionID() {
        let event = HookEvent(
            sessionId: "qoderwork-session",
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
                        "header": "技能",
                        "question": "你最想了解哪个功能？",
                        "options": [
                            ["label": "MCP 工具集成"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        XCTAssertTrue(event.isAskUserQuestionRequest)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertEqual(
            event.intervention?.id,
            "qoderwork-question-qoderwork-session-topic"
        )
        XCTAssertFalse(event.intervention?.supportsInlineResponse ?? true)
        XCTAssertEqual(event.intervention?.metadata["responseMode"], "external_only")
        XCTAssertEqual(event.determinePhase(), .waitingForInput)
    }

    func testQoderWorkBridgeQuestionUsesToolInputForExternalModeAndDefaultAnswer() {
        let bridgeIntervention = SessionIntervention(
            id: "call_bridge",
            kind: .question,
            title: "Claude needs input",
            message: "Choose one",
            options: [
                .init(id: "topic:0", title: "A 方案", detail: nil),
                .init(id: "topic:1", title: "B 方案", detail: nil)
            ],
            questions: [],
            supportsSessionScope: false,
            metadata: ["tool_name": "AskUserQuestion"]
        )
        let event = HookEvent(
            sessionId: "qoderwork-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
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
            toolUseId: "call_bridge",
            notificationType: nil,
            message: nil,
            bridgeIntervention: bridgeIntervention
        )

        XCTAssertEqual(event.intervention?.metadata["responseMode"], "external_only")
        XCTAssertFalse(event.intervention?.supportsInlineResponse ?? true)
        XCTAssertEqual(event.intervention?.questions.first?.options.first?.title, "A 方案")

        let autoAnswer = SessionMonitor.defaultQoderAutoAnswer(for: event)
        XCTAssertEqual(autoAnswer?.toolUseId, "call_bridge")
        XCTAssertEqual(autoAnswer?.answers["topic"], ["A 方案"])
        let answers = autoAnswer?.updatedInput["answers"] as? [String: Any]
        XCTAssertEqual(answers?["topic"] as? String, "A 方案")
        XCTAssertEqual(answers?["先选一个主题"] as? String, "A 方案")
    }

    func testWorkBuddyPreToolUseQuestionUsesExternalClientMode() {
        let event = HookEvent(
            sessionId: "workbuddy-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "技能",
                        "question": "你最想了解哪个功能？",
                        "options": [
                            ["label": "MCP 工具集成"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_workbuddy_123",
            notificationType: nil,
            message: nil
        )

        XCTAssertTrue(event.isAskUserQuestionRequest)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertEqual(event.intervention?.id, "call_workbuddy_123")
        XCTAssertFalse(event.intervention?.supportsInlineResponse ?? true)
        XCTAssertEqual(event.intervention?.metadata["responseMode"], "external_only")
        XCTAssertTrue(event.intervention?.message.contains("暂不支持直接提交") ?? false)
        XCTAssertEqual(event.determinePhase(), .waitingForInput)
    }

    func testWorkBuddyAutoAnswerUsesFirstOptionForEveryQuestion() {
        let event = HookEvent(
            sessionId: "workbuddy-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            ),
            pid: nil,
            tty: nil,
            tool: "ask_followup_question",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "技能",
                        "question": "你最想了解哪个功能？",
                        "options": [
                            ["label": "MCP 工具集成"],
                            ["label": "审批流"]
                        ]
                    ],
                    [
                        "id": "style",
                        "header": "风格",
                        "question": "再选一个风格",
                        "options": [
                            "简洁",
                            "详细"
                        ]
                    ]
                ])
            ],
            toolUseId: "call_workbuddy_followup",
            notificationType: nil,
            message: nil
        )

        let autoAnswer = SessionMonitor.defaultQoderAutoAnswer(for: event)

        XCTAssertEqual(autoAnswer?.toolUseId, "call_workbuddy_followup")
        XCTAssertEqual(autoAnswer?.answers["topic"], ["MCP 工具集成"])
        XCTAssertEqual(autoAnswer?.answers["style"], ["简洁"])
        let updatedInput = autoAnswer?.updatedInput
        let answers = updatedInput?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["topic"] as? String, "MCP 工具集成")
        XCTAssertEqual(answers?["style"] as? String, "简洁")
    }

    func testWorkBuddyDoesNotAutoAnswerWhenAQuestionHasNoOptions() {
        let event = HookEvent(
            sessionId: "workbuddy-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            ),
            pid: nil,
            tty: nil,
            tool: "ask_followup_question",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "技能",
                        "question": "你最想了解哪个功能？",
                        "options": [
                            ["label": "MCP 工具集成"],
                            ["label": "审批流"]
                        ]
                    ],
                    [
                        "id": "path",
                        "header": "文件",
                        "question": "请告诉我文件的路径或名称",
                        "options": []
                    ]
                ])
            ],
            toolUseId: "call_workbuddy_free_text",
            notificationType: nil,
            message: nil
        )

        XCTAssertNil(SessionMonitor.defaultQoderAutoAnswer(for: event))
    }

    func testQoderAutoAnswerUsesFirstOptionForEveryQuestion() {
        let event = HookEvent(
            sessionId: "qoder-session",
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
                    ],
                    [
                        "id": "style",
                        "header": "风格",
                        "question": "再选一个风格",
                        "options": [
                            "简洁",
                            "详细"
                        ]
                    ]
                ])
            ],
            toolUseId: "call_auto",
            notificationType: nil,
            message: nil
        )

        let autoAnswer = SessionMonitor.defaultQoderAutoAnswer(for: event)

        XCTAssertEqual(autoAnswer?.toolUseId, "call_auto")
        XCTAssertEqual(autoAnswer?.answers["topic"], ["A 方案"])
        XCTAssertEqual(autoAnswer?.answers["style"], ["简洁"])
        let updatedInput = autoAnswer?.updatedInput
        let answers = updatedInput?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["topic"] as? String, "A 方案")
        XCTAssertEqual(answers?["style"] as? String, "简洁")
    }

    func testQoderCLIDoesNotUseQoderIDEAutoAnswerFallback() {
        let event = HookEvent(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI"
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
            toolUseId: "call_auto",
            notificationType: nil,
            message: nil
        )

        XCTAssertNil(SessionMonitor.defaultQoderAutoAnswer(for: event))
    }

    func testQoderCLIWithGenericQoderProfileStillRequiresResponse() {
        let event = HookEvent(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder",
                name: "Qoder CLI",
                origin: "cli",
                originator: "Qoder"
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
            toolUseId: "call_cli",
            notificationType: nil,
            message: nil
        )

        XCTAssertEqual(event.clientInfo.normalizedForClaudeRouting().profileID, "qoder-cli")
        XCTAssertTrue(event.isAskUserQuestionRequest)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertTrue(event.expectsResponse)
        XCTAssertEqual(event.determinePhase(), .waitingForInput)
    }

    func testQoderWorkAutoAnswerUsesFirstOptionForEveryQuestion() {
        let event = HookEvent(
            sessionId: "qoderwork-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
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
            toolUseId: "call_auto",
            notificationType: nil,
            message: nil
        )

        let autoAnswer = SessionMonitor.defaultQoderAutoAnswer(for: event)

        XCTAssertEqual(autoAnswer?.toolUseId, "call_auto")
        XCTAssertEqual(autoAnswer?.answers["topic"], ["A 方案"])
        let updatedInput = autoAnswer?.updatedInput
        let answers = updatedInput?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["topic"] as? String, "A 方案")
        XCTAssertEqual(answers?["先选一个主题"] as? String, "A 方案")
    }
}
