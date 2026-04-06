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

        let autoAnswer = SessionMonitor.defaultQoderWorkAutoAnswer(for: event)

        XCTAssertEqual(autoAnswer?.toolUseId, "call_auto")
        XCTAssertEqual(autoAnswer?.answers["topic"], ["A 方案"])
        XCTAssertEqual(autoAnswer?.answers["style"], ["简洁"])
        let updatedInput = autoAnswer?.updatedInput
        let answers = updatedInput?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["topic"] as? String, "A 方案")
        XCTAssertEqual(answers?["style"] as? String, "简洁")
    }
}
