import XCTest
@testable import Ping_Island

final class SessionManualAttentionTrackerTests: XCTestCase {
    func testApprovalToolUseRefreshInSameSessionTriggersAttentionAgain() {
        var tracker = SessionManualAttentionTracker()
        let firstApproval = makeApprovalSession(toolUseId: "tool-1")
        let secondApproval = makeApprovalSession(toolUseId: "tool-2")

        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [firstApproval])?.stableId,
            firstApproval.stableId
        )
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [firstApproval]))
        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [secondApproval])?.stableId,
            secondApproval.stableId
        )
    }

    private func makeApprovalSession(toolUseId: String) -> SessionState {
        SessionState(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI"
            ),
            phase: .waitingForApproval(PermissionContext(
                toolUseId: toolUseId,
                toolName: "ExitPlanMode",
                toolInput: ["plan": AnyCodable("Plan text")],
                receivedAt: Date()
            ))
        )
    }
}
