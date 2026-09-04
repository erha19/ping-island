import XCTest
@testable import Ping_Island

final class OmpAskQuestionTests: XCTestCase {
    func testOmpAskToolCreatesQuestionIntervention() {
        let event = HookEvent(
            sessionId: "omp-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .omp,
            clientInfo: SessionClientInfo(
                kind: .omp,
                profileID: "omp-hooks",
                name: "Oh My Pi",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call-1",
            notificationType: nil,
            message: nil,
            bridgeExpectsResponse: true
        )

        XCTAssertTrue(event.isAskUserQuestionRequest)
        XCTAssertFalse(event.isAnsweredAskUserQuestionEvent)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertEqual(event.intervention?.questions.first?.prompt, "先选一个主题")
    }

    func testOmpAskMultiQuestionSetsAllowsMultiple() {
        let event = HookEvent(
            sessionId: "omp-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .omp,
            clientInfo: SessionClientInfo(
                kind: .omp,
                profileID: "omp-hooks",
                name: "Oh My Pi",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "scopes",
                        "question": "需要覆盖哪些范围",
                        "multi": true,
                        "options": [
                            ["label": "核心流程"],
                            ["label": "边界情况"],
                            ["label": "文档"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call-2",
            notificationType: nil,
            message: nil,
            bridgeExpectsResponse: true
        )

        let question = event.intervention?.questions.first
        XCTAssertEqual(question?.prompt, "需要覆盖哪些范围")
        XCTAssertTrue(question?.allowsMultiple ?? false)
        XCTAssertEqual(question?.options.count, 3)
    }

    func testOmpAskAnsweredNotificationDoesNotCreateIntervention() {
        let event = HookEvent(
            sessionId: "omp-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .omp,
            clientInfo: SessionClientInfo(
                kind: .omp,
                profileID: "omp-hooks",
                name: "Oh My Pi",
                origin: "cli"
            ),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"]
                        ]
                    ]
                ]),
                "answers": AnyCodable([
                    "先选一个主题": "A 方案"
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        XCTAssertTrue(event.isAnsweredAskUserQuestionEvent)
        XCTAssertFalse(event.isAskUserQuestionRequest)
        XCTAssertNil(event.intervention)
    }

    func testNonOmpAskToolIsNotTreatedAsQuestionTool() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "running_tool",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "Ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call-1",
            notificationType: nil,
            message: nil
        )

        XCTAssertFalse(event.isAskUserQuestionRequest)
        XCTAssertFalse(event.isAnsweredAskUserQuestionEvent)
        XCTAssertNil(event.intervention)
    }
}
