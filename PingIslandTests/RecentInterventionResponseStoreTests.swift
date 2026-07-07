import Foundation
import XCTest
@testable import Ping_Island

final class RecentInterventionResponseStoreTests: XCTestCase {
    func testQoderWorkAnswerCanBeReplayedForDuplicatePermissionRequest() {
        var store = RecentInterventionResponseStore(ttl: 30)

        let preToolEvent = HookEvent(
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
                        "id": "drink",
                        "header": "偏好",
                        "question": "你更喜欢喝什么？",
                        "options": [
                            ["label": "绿茶"],
                            ["label": "咖啡"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_123",
            notificationType: nil,
            message: nil
        )

        let permissionEvent = HookEvent(
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
                        "id": "drink",
                        "header": "偏好",
                        "question": "你更喜欢喝什么？",
                        "multiSelect": false,
                        "options": [
                            ["label": "绿茶"],
                            ["label": "咖啡"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        store.record(
            event: preToolEvent,
            decision: "answer",
            reason: nil,
            updatedInput: [
                "answers": AnyCodable(["drink": "绿茶"])
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        let replay = store.response(
            for: permissionEvent,
            now: Date(timeIntervalSince1970: 105)
        )

        XCTAssertEqual(replay?.decision, "answer")
        XCTAssertEqual(replay?.updatedInput?["answers"]?.value as? [String: String], ["drink": "绿茶"])
    }

    func testRecordedAnswerExpiresAfterTTL() {
        var store = RecentInterventionResponseStore(ttl: 5)

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
                        "id": "drink",
                        "header": "偏好",
                        "question": "你更喜欢喝什么？"
                    ]
                ])
            ],
            toolUseId: "call_123",
            notificationType: nil,
            message: nil
        )

        store.record(
            event: event,
            decision: "answer",
            reason: nil,
            updatedInput: ["answers": AnyCodable(["drink": "绿茶"])],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(store.response(for: event, now: Date(timeIntervalSince1970: 106)))
    }

    func testClaudeAnswerCanBeReplayedForDuplicateAskUserQuestionPermissionRequest() {
        var store = RecentInterventionResponseStore(ttl: 30)

        let questionEvent = HookEvent(
            sessionId: "claude-session",
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
            toolUseId: "toolu_123",
            notificationType: nil,
            message: nil
        )

        let duplicatePermissionEvent = HookEvent(
            sessionId: "claude-session",
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
            toolUseId: "toolu_123",
            notificationType: nil,
            message: nil
        )

        store.record(
            event: questionEvent,
            decision: "answer",
            reason: nil,
            updatedInput: [
                "answers": AnyCodable(["project": "会话层"])
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        let replay = store.response(
            for: duplicatePermissionEvent,
            now: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(replay?.decision, "answer")
        XCTAssertEqual(replay?.updatedInput?["answers"]?.value as? [String: String], ["project": "会话层"])
    }

    func testQoderCLIAnswerCanReplayToAnsweredPermissionRequestInsideQoderIDE() {
        var store = RecentInterventionResponseStore(ttl: 30)
        let clientInfo = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder-cli",
            name: "Qoder CLI",
            origin: "cli",
            terminalBundleIdentifier: "com.qoder.ide"
        )

        let questionEvent = HookEvent(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
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
                        "header": "Task type",
                        "question": "What would you like to work on today?",
                        "options": [
                            ["label": "Write new code"],
                            ["label": "Debug or fix a bug"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_123",
            notificationType: nil,
            message: nil
        )

        let answeredPermissionEvent = HookEvent(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "processing",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "header": "Task type",
                        "question": "What would you like to work on today?",
                        "options": [
                            ["label": "Write new code"],
                            ["label": "Debug or fix a bug"]
                        ]
                    ]
                ]),
                "answers": AnyCodable([
                    "What would you like to work on today?": "Write new code"
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        store.record(
            event: questionEvent,
            decision: "answer",
            reason: nil,
            updatedInput: [
                "answers": AnyCodable([
                    "What would you like to work on today?": "Write new code"
                ])
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        let replay = store.response(
            for: answeredPermissionEvent,
            now: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(replay?.decision, "answer")
        XCTAssertEqual(
            replay?.updatedInput?["answers"]?.value as? [String: String],
            ["What would you like to work on today?": "Write new code"]
        )
    }

    func testCodeBuddyCLINotificationAnswerCanReplayToPermissionRequest() {
        var store = RecentInterventionResponseStore(ttl: 30)

        let clientInfo = SessionClientInfo(
            kind: .qoder,
            profileID: "codebuddy-cli",
            name: "CodeBuddy CLI",
            origin: "cli"
        )
        let notificationEvent = HookEvent(
            sessionId: "codebuddy-cli-session",
            cwd: "/tmp/project",
            event: "Notification",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: clientInfo,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: "bridge-123",
            notificationType: "permission_prompt",
            message: "needs your permission to use AskUserQuestion"
        )
        let permissionEvent = HookEvent(
            sessionId: "codebuddy-cli-session",
            cwd: "/tmp/project",
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
                        "id": "scope",
                        "header": "范围",
                        "question": "这次要修哪里？",
                        "options": [
                            ["label": "SessionStore"],
                            ["label": "UI 卡片"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call-123",
            notificationType: nil,
            message: nil
        )

        store.record(
            event: notificationEvent,
            decision: "answer",
            reason: nil,
            updatedInput: [
                "questions": AnyCodable([
                    [
                        "id": "scope",
                        "header": "范围",
                        "question": "这次要修哪里？",
                        "options": [
                            ["label": "SessionStore"],
                            ["label": "UI 卡片"]
                        ]
                    ]
                ]),
                "answers": AnyCodable([
                    "scope": "SessionStore",
                    "q_0": "SessionStore"
                ])
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        let replay = store.response(
            for: permissionEvent,
            now: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(replay?.decision, "answer")
        XCTAssertEqual(replay?.updatedInput?["answers"]?.value as? [String: String], [
            "scope": "SessionStore",
            "q_0": "SessionStore"
        ])
    }
}
