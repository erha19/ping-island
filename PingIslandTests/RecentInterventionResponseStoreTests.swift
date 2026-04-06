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
}
