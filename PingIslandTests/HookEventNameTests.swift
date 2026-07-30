import XCTest
@testable import NotchCode

final class HookEventNameTests: XCTestCase {
    func testCursorCamelCaseEventsNormalizeToClaudeNames() {
        XCTAssertEqual(HookEventName.normalized("stop"), "Stop")
        XCTAssertEqual(HookEventName.normalized("Stop"), "Stop")
        XCTAssertEqual(HookEventName.normalized("postToolUse"), "PostToolUse")
        XCTAssertEqual(HookEventName.normalized("preToolUse"), "PreToolUse")
        XCTAssertEqual(HookEventName.normalized("beforeSubmitPrompt"), "UserPromptSubmit")
        XCTAssertEqual(HookEventName.normalized("sessionEnd"), "SessionEnd")
        XCTAssertEqual(HookEventName.normalized("sessionStart"), "SessionStart")
        XCTAssertEqual(HookEventName.normalized("subagentStop"), "SubagentStop")
        XCTAssertEqual(HookEventName.normalized("preCompact"), "PreCompact")
    }

    func testCursorStopWithoutBridgeStatusMapsToWaitingForInputNotProcessing() {
        let status = HookEventName.mapStatus(
            eventType: "stop",
            bridgeStatusKind: nil,
            notificationType: nil,
            provider: .claude
        )
        XCTAssertEqual(status, "waiting_for_input")

        let event = HookEvent(
            sessionId: "cursor-session-1",
            cwd: "/tmp/project",
            event: HookEventName.normalized("stop"),
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "cursor-hooks",
                name: "Cursor"
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        XCTAssertEqual(event.event, "Stop")
        let phase = event.determinePhase()
        guard case .waitingForInput = phase else {
            XCTFail("Expected waitingForInput, got \(phase)")
            return
        }
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: phase,
                hasPendingPermission: false,
                hasHumanIntervention: false
            ),
            .idle
        )
    }

    func testHistoricalThinkingIsNotLiveExecutionEvidence() {
        var session = SessionState(
            sessionId: "think-1",
            cwd: "/tmp/project",
            phase: .processing
        )
        session.chatItems = [
            ChatHistoryItem(id: "t1", type: .thinking("planning"), timestamp: Date()),
        ]

        XCTAssertFalse(SessionExecutionEvidence.hasLiveExecution(session))
    }

    func testRunningToolIsLiveExecutionEvidence() {
        var session = SessionState(
            sessionId: "tool-1",
            cwd: "/tmp/project",
            phase: .processing
        )
        session.chatItems = [
            ChatHistoryItem(
                id: "tool-1",
                type: .toolCall(ToolCallItem(
                    name: "Shell",
                    input: [:],
                    status: .running,
                    result: nil,
                    structuredResult: nil,
                    subagentTools: []
                )),
                timestamp: Date()
            ),
        ]

        XCTAssertTrue(SessionExecutionEvidence.hasLiveExecution(session))
    }
}
