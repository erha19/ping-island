import Foundation
import XCTest
@testable import NotchCode

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

    func testNotLoadedStatusInfersPhaseFromTurns() {
        XCTAssertTrue(
            CodexAppServerMonitor.shouldInferPhaseFromTurns(status: ["type": "notLoaded"])
        )
        XCTAssertFalse(
            CodexAppServerMonitor.shouldInferPhaseFromTurns(status: ["type": "active"])
        )

        XCTAssertEqual(
            CodexAppServerMonitor.phaseInferredFromTurns([
                ["status": "inProgress", "startedAt": 1]
            ]),
            .processing
        )
        XCTAssertEqual(
            CodexAppServerMonitor.phaseInferredFromTurns([
                ["status": "completed", "startedAt": 1, "completedAt": 2]
            ]),
            .idle
        )
        XCTAssertEqual(
            CodexAppServerMonitor.phaseInferredFromTurns([
                ["startedAt": 1]
            ]),
            .processing
        )
        // Desktop-owned turns often surface as `interrupted` without completedAt while
        // the rollout is still growing; treat that as live work, not idle history.
        XCTAssertEqual(
            CodexAppServerMonitor.phaseInferredFromTurns([
                ["status": "interrupted", "startedAt": 1]
            ]),
            .processing
        )
    }

    func testPreferredCodexSyncSnapshotKeepsActiveRolloutOverStaleIdleAppServer() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let idleAppServer = makeSnapshot(
            threadId: "thread-1",
            updatedAt: newer,
            phase: .idle,
            historyItemCount: 4
        )
        let activeRollout = makeSnapshot(
            threadId: "thread-1",
            updatedAt: older,
            phase: .processing,
            historyItemCount: 3
        )

        let preferred = CodexThreadSnapshot.preferredForSync(
            rollout: activeRollout,
            appServer: idleAppServer
        )

        XCTAssertEqual(preferred.snapshot.phase, .processing)
        XCTAssertEqual(preferred.ingress, .hookBridge)
    }

    func testPreferredCodexSyncSnapshotAppliesAppServerInsteadOfDroppingBoth() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let activeAppServer = makeSnapshot(
            threadId: "thread-1",
            updatedAt: newer,
            phase: .processing,
            historyItemCount: 5
        )
        let quieterRollout = makeSnapshot(
            threadId: "thread-1",
            updatedAt: older,
            phase: .idle,
            historyItemCount: 2
        )

        let preferred = CodexThreadSnapshot.preferredForSync(
            rollout: quieterRollout,
            appServer: activeAppServer
        )

        XCTAssertEqual(preferred.snapshot.phase, .processing)
        XCTAssertEqual(preferred.ingress, .codexAppServer)
    }

    private func makeSnapshot(
        threadId: String,
        updatedAt: Date,
        phase: SessionPhase,
        historyItemCount: Int
    ) -> CodexThreadSnapshot {
        let historyItems = (0..<historyItemCount).map { index in
            ChatHistoryItem(
                id: "item-\(index)",
                type: .assistant("message-\(index)"),
                timestamp: updatedAt
            )
        }
        return CodexThreadSnapshot(
            threadId: threadId,
            name: "Codex",
            preview: "preview",
            cwd: "/tmp/project",
            clientInfo: .codexApp(threadId: threadId),
            intervention: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            phase: phase,
            historyItems: historyItems,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "message",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            latestTurnId: nil,
            latestResponseText: "message",
            latestResponsePhase: "final",
            latestUserText: nil
        )
    }
}
