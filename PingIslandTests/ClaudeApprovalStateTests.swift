import XCTest
@testable import NotchCode

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

    func testSupersededPermissionRequestCancelsPreviousPendingHookResponse() async {
        let sessionId = "claude-approval-superseded-\(UUID().uuidString)"
        let store = SessionStore.shared
        let recorder = PendingHookCancellationRecorder()

        await store.setPendingHookResponseCancellationHandlerForTesting { toolUseId, ingress in
            recorder.record(toolUseId: toolUseId, ingress: ingress)
            Task { @MainActor in
                if ingress == .hookBridge {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            }
        }

        await store.process(.hookReceived(makeToolEvent(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Read",
            toolUseId: "tool-read"
        )))
        await store.process(.hookReceived(makeToolEvent(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Grep",
            toolUseId: "tool-grep"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.activePermission?.toolUseId, "tool-grep")
        XCTAssertEqual(recorder.toolUseIds, ["tool-read"])

        await store.process(.sessionArchived(sessionId: sessionId))
        await store.setPendingHookResponseCancellationHandlerForTesting(nil)
    }

    func testCachedToolUseIdClearsBridgeApprovalInterventionAfterApproval() async {
        let sessionId = "claude-approval-cached-\(UUID().uuidString)"
        let store = SessionStore.shared
        let bridgeIntervention = SessionIntervention(
            id: "bridge-generated-approval-id",
            kind: .approval,
            title: "Claude needs approval",
            message: "Write",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: ["tool_name": "Write"]
        )

        let permissionEvent = makeToolEvent(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Write",
            toolUseId: "",
            bridgeIntervention: bridgeIntervention
        ).withToolUseId("toolu-write-1")

        await store.process(.hookReceived(permissionEvent))

        var session = await store.session(for: sessionId)
        XCTAssertTrue(session?.needsApprovalResponse ?? false)
        XCTAssertEqual(session?.activePermission?.toolUseId, "toolu-write-1")
        XCTAssertEqual(session?.intervention?.id, "bridge-generated-approval-id")
        XCTAssertEqual(session?.intervention?.metadata["tool_use_id"], "toolu-write-1")

        await store.process(.permissionApproved(sessionId: sessionId, toolUseId: "toolu-write-1"))

        session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

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

private final class PendingHookCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(toolUseId: String, ingress: SessionIngress)] = []

    var toolUseIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.toolUseId)
    }

    func record(toolUseId: String, ingress: SessionIngress) {
        lock.lock()
        records.append((toolUseId, ingress))
        lock.unlock()
    }
}
