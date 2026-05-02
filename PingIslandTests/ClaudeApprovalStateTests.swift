import XCTest
@testable import Ping_Island

final class ClaudeApprovalStateTests: XCTestCase {
    func testWaitingApprovalStatusMapsToApprovalPhaseForPreToolUse() {
        let event = makeToolEvent(
            sessionId: "qoder-cli-exit-plan",
            event: "PreToolUse",
            status: "waiting_for_approval",
            tool: "ExitPlanMode",
            toolUseId: "tool-exit-plan"
        )

        let phase = event.determinePhase()
        XCTAssertTrue(phase.isWaitingForApproval)
        XCTAssertEqual(phase.approvalToolName, "ExitPlanMode")
    }

    func testBridgeInterventionIsPreservedForExitPlanModeApproval() {
        let bridgeIntervention = SessionIntervention(
            id: "intervention-exit-plan",
            kind: .approval,
            title: "Qoder CLI needs plan approval",
            message: "Qoder CLI wants to exit plan mode and start coding.",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: ["tool_name": "ExitPlanMode"]
        )
        let event = makeToolEvent(
            sessionId: "qoder-cli-exit-plan",
            event: "PreToolUse",
            status: "waiting_for_approval",
            tool: "ExitPlanMode",
            toolUseId: "tool-exit-plan",
            bridgeIntervention: bridgeIntervention
        )

        XCTAssertEqual(event.intervention, bridgeIntervention)
    }

    func testExitPlanModeApprovalRevivesEndedQoderCLISession() async {
        let sessionId = "qoder-cli-ended-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderCLIEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "ended",
            tool: "Stop",
            toolUseId: "stop"
        )))
        await store.process(.hookReceived(makeQoderCLIEvent(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "waiting_for_approval",
            tool: "ExitPlanMode",
            toolUseId: "tool-exit-plan"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval ?? false)
        XCTAssertEqual(session?.activePermission?.toolUseId, "tool-exit-plan")
        XCTAssertTrue(session?.needsApprovalResponse ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testUnrelatedPostToolUseDoesNotClearPendingClaudeApproval() async {
        let sessionId = "claude-approval-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeToolEvent(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Bash",
            toolUseId: "tool-approve"
        )))
        await store.process(.hookReceived(makeToolEvent(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolUseId: "tool-approve"
        )))
        await store.process(.hookReceived(makeToolEvent(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Read",
            toolUseId: "tool-other"
        )))
        await store.process(.hookReceived(makeToolEvent(
            sessionId: sessionId,
            event: "PostToolUse",
            status: "processing",
            tool: "Read",
            toolUseId: "tool-other"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.phase.isWaitingForApproval ?? false)
        XCTAssertEqual(session?.activePermission?.toolUseId, "tool-approve")
        XCTAssertEqual(session?.activePermission?.toolName, "Bash")
        XCTAssertEqual(session?.pendingToolName, "Bash")
        XCTAssertTrue(session?.needsApprovalResponse ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func makeToolEvent(
        sessionId: String,
        event: String,
        status: String,
        tool: String,
        toolUseId: String,
        bridgeIntervention: SessionIntervention? = nil
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
            toolInput: ["command": AnyCodable("swift test")],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil,
            bridgeIntervention: bridgeIntervention
        )
    }

    private func makeQoderCLIEvent(
        sessionId: String,
        event: String,
        status: String,
        tool: String,
        toolUseId: String
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli",
                originator: "Qoder",
                terminalBundleIdentifier: "com.googlecode.iterm2"
            ),
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: [:],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }
}
