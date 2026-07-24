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

    func testRecentNotLoadedThreadRequestsRolloutRecovery() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        let thread: [String: Any] = [
            "id": "vscode-thread",
            "updatedAt": referenceDate.addingTimeInterval(-15).timeIntervalSince1970,
            "recencyAt": referenceDate.addingTimeInterval(-30).timeIntervalSince1970,
            "status": ["type": "notLoaded"]
        ]

        XCTAssertNotNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: thread,
            referenceDate: referenceDate
        ))
    }

    func testNotLoadedThreadRecoveryUsesRecencyTimestampWhenUpdatedTimestampIsMissing() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        let thread: [String: Any] = [
            "id": "vscode-thread",
            "recencyAt": referenceDate.addingTimeInterval(-15).timeIntervalSince1970,
            "status": ["type": "notLoaded"]
        ]

        XCTAssertNotNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: thread,
            referenceDate: referenceDate
        ))
    }

    func testLoadedAndStaleThreadsDoNotRequestRolloutRecovery() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        let recentTimestamp = referenceDate.addingTimeInterval(-15).timeIntervalSince1970
        let staleTimestamp = referenceDate.addingTimeInterval(-(11 * 60)).timeIntervalSince1970

        XCTAssertNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: [
                "id": "loaded-thread",
                "updatedAt": recentTimestamp,
                "status": ["type": "active"]
            ],
            referenceDate: referenceDate
        ))
        XCTAssertNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: [
                "id": "stale-thread",
                "updatedAt": staleTimestamp,
                "status": ["type": "notLoaded"]
            ],
            referenceDate: referenceDate
        ))
    }

    func testNotLoadedRecoveryVersionChangesWhenActivityAdvances() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        var thread: [String: Any] = [
            "id": "vscode-thread",
            "updatedAt": referenceDate.addingTimeInterval(-30).timeIntervalSince1970,
            "status": ["type": "notLoaded"]
        ]
        let initialVersion = try XCTUnwrap(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: thread,
            referenceDate: referenceDate
        ))

        thread["updatedAt"] = referenceDate.addingTimeInterval(-5).timeIntervalSince1970

        XCTAssertNotEqual(
            initialVersion,
            CodexAppServerMonitor.notLoadedRecoveryVersion(
                from: thread,
                referenceDate: referenceDate
            )
        )
    }

    func testRolloutPathAcceptsJSONLPathWithoutTreatingWorkspaceAsSessionFile() {
        XCTAssertEqual(
            CodexAppServerMonitor.rolloutPath(from: [
                "path": "/tmp/codex/rollout-vscode-thread.jsonl"
            ]),
            "/tmp/codex/rollout-vscode-thread.jsonl"
        )
        XCTAssertNil(CodexAppServerMonitor.rolloutPath(from: [
            "path": "/tmp/codex-workspace"
        ]))
    }
}
