import Foundation
import XCTest
@testable import Ping_Island

final class CodexAppServerMonitorTests: XCTestCase {
    func testWebSocketTaskAllowsLargeCodexMessages() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:41241"))
        let task = CodexAppServerMonitor.makeWebSocketTask(url: url)
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        XCTAssertEqual(task.maximumMessageSize, CodexAppServerMonitor.maximumWebSocketMessageSize)
        XCTAssertGreaterThan(task.maximumMessageSize, 1_214_839)
    }

    func testWebSocketPayloadsEncodeAsTextJSON() throws {
        let message = try CodexAppServerMonitor.webSocketTextMessage(from: [
            "jsonrpc": "2.0",
            "id": "1",
            "method": "initialize",
            "params": [
                "capabilities": [
                    "experimentalApi": true
                ],
                "clientInfo": [
                    "name": "Island",
                    "title": "Island",
                    "version": "0.0.4"
                ]
            ]
        ])

        let data = try XCTUnwrap(message.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? String, "1")
        XCTAssertEqual(json["method"] as? String, "initialize")

        let params = try XCTUnwrap(json["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "Island")
    }

    func testGuardianReviewInterventionMapsMcpToolApprovalToExternalReminder() throws {
        let intervention = try XCTUnwrap(
            CodexAppServerMonitor.guardianReviewIntervention(from: [
                "threadId": "thread-1",
                "targetItemId": "item-1",
                "review": [
                    "status": "inProgress"
                ],
                "action": [
                    "type": "mcpToolCall",
                    "server": "omx_state",
                    "toolName": "state_list_active"
                ]
            ])
        )

        XCTAssertEqual(intervention.kind, .question)
        XCTAssertEqual(intervention.title, "MCP Tool Approval Needed")
        XCTAssertEqual(
            intervention.message,
            "Allow the omx_state MCP server to run tool \"state_list_active\"?"
        )
        XCTAssertEqual(intervention.metadata["responseMode"], "external_only")
        XCTAssertEqual(intervention.metadata["source"], "guardian_review")
    }

    func testCodexUserInputQuestionsDefaultToCustomInput() {
        let questions = CodexAppServerMonitor.parseQuestions([
            [
                "id": "scope",
                "header": "Scope",
                "question": "Where should Codex focus?",
                "options": [
                    ["label": "Tests"],
                    ["label": "UI"]
                ]
            ]
        ])

        XCTAssertEqual(questions.first?.options.map(\.title), ["Tests", "UI"])
        XCTAssertTrue(questions.first?.allowsOther ?? false)
    }

    func testRecentIdleThreadRequestsRolloutRecoveryAfterReconnect() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_481_907)
        let recentUpdate = referenceDate.addingTimeInterval(-93).timeIntervalSince1970
        let rolloutPath = "/tmp/ping-island-tests/rollout-thread-with-recent-activity.jsonl"
        let thread: [String: Any] = [
            "id": "thread-with-recent-activity",
            "updatedAt": recentUpdate,
            "status": ["type": "idle"],
            "path": rolloutPath
        ]

        XCTAssertTrue(CodexAppServerMonitor.shouldRecoverRolloutSnapshot(
            from: thread,
            referenceDate: referenceDate
        ))
        XCTAssertEqual(CodexAppServerMonitor.rolloutPath(from: thread), rolloutPath)
    }

    func testActiveThreadRequestsRolloutRecoveryDespiteStaleTimestamp() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_481_907)

        XCTAssertTrue(CodexAppServerMonitor.shouldRecoverRolloutSnapshot(
            from: [
                "id": "active-thread",
                "updatedAt": referenceDate.addingTimeInterval(-(60 * 60)).timeIntervalSince1970,
                "status": ["type": "active"]
            ],
            referenceDate: referenceDate
        ))
    }

    func testStaleIdleThreadDoesNotRequestRolloutRecovery() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_481_907)
        let staleUpdate = referenceDate.addingTimeInterval(-(31 * 60)).timeIntervalSince1970

        XCTAssertFalse(CodexAppServerMonitor.shouldRecoverRolloutSnapshot(
            from: [
                "id": "stale-thread",
                "updatedAt": staleUpdate,
                "status": ["type": "idle"]
            ],
            referenceDate: referenceDate
        ))
    }
}
