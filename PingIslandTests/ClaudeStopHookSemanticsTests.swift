import XCTest
@testable import Ping_Island

/// Integration tests for the Stop / SubagentStop / SessionEnd hook semantics
/// introduced by the `fix-claude-sound-triggers` change. These verify that the
/// new mapping (Stop → "waiting_for_input", SubagentStop → "running_tool",
/// SessionEnd → "ended") flows through `SessionStore.processHookEvent` without
/// invoking `markSessionEnded` for the non-terminating events.
final class ClaudeStopHookSemanticsTests: XCTestCase {

    func testClaudeStopKeepsSessionAliveAndPreservesAutoApprove() async {
        let sessionId = "claude-stop-alive-\(UUID().uuidString)"
        let store = SessionStore.shared

        // Prime: arrive via UserPromptSubmit so the session exists in processing.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))

        // Arm autoApprove on the live session — markSessionEnded would clear it.
        await store.process(
            .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
        )

        // Now the Stop event arrives, post-mapping, as "waiting_for_input".
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertNotNil(session, "Session must remain in store after Stop")
        XCTAssertEqual(session?.phase, .waitingForInput,
                       "Stop with new mapping must land in .waitingForInput, not .ended")
        XCTAssertTrue(session?.autoApprovePermissions ?? false,
                      "markSessionEnded clears autoApprovePermissions; preservation proves it was NOT called")
        XCTAssertNil(session?.intervention)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testClaudeSubagentStopDoesNotEndParentSession() async {
        let sessionId = "claude-subagent-\(UUID().uuidString)"
        let store = SessionStore.shared

        // Prime: parent session is actively running a Task tool.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Task",
            toolUseId: "task-1"
        )))
        await store.process(
            .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
        )

        // SubagentStop arrives, post-mapping, as "running_tool" (parent stays processing).
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "SubagentStop",
            status: "running_tool"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertNotNil(session, "Parent session must survive SubagentStop")
        XCTAssertNotEqual(session?.phase, .ended,
                          "SubagentStop must NOT mark the parent session as ended")
        XCTAssertTrue(session?.autoApprovePermissions ?? false,
                      "markSessionEnded clears autoApprovePermissions; preservation proves it was NOT called")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testClaudeSessionEndStillTerminatesSession() async {
        let sessionId = "claude-end-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(
            .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
        )

        // SessionEnd remains the sole terminating event — status "ended".
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "SessionEnd",
            status: "ended"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .ended,
                       "SessionEnd MUST still mark the session as .ended")
        XCTAssertFalse(session?.autoApprovePermissions ?? true,
                       "markSessionEnded clears autoApprovePermissions on a real SessionEnd")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    // MARK: - Helpers

    private func makeClaudeEvent(
        sessionId: String,
        event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: tool != nil ? [:] : nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }
}
