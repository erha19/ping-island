import XCTest
@testable import Ping_Island

final class SessionManualAttentionTrackerTests: XCTestCase {
    func testConsecutiveInterventionOnlyApprovalsTriggerAttention() {
        var tracker = SessionManualAttentionTracker()
        let first = makeInterventionApproval(id: "approval-1")
        let second = makeInterventionApproval(id: "approval-2")

        XCTAssertEqual(tracker.consumeNewAttentionSession(from: [first]), first)
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [first]))
        XCTAssertEqual(tracker.consumeNewAttentionSession(from: [second]), second)
    }

    func testConsecutiveInterventionOnlyApprovalsHaveIndependentDelays() {
        var tracker = SessionManualAttentionTracker()
        let now = Date()
        let first = makeInterventionApproval(id: "approval-1", autoApprove: true)
        let second = makeInterventionApproval(id: "approval-2", autoApprove: true)
        let delay = SessionManualAttentionTracker.autoApproveApprovalNotificationDelay

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [first], now: now))
        XCTAssertEqual(tracker.consumeNewAttentionSession(from: [first], now: now.addingTimeInterval(delay)), first)
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [second], now: now.addingTimeInterval(delay + 1)))
        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [second], now: now.addingTimeInterval(2 * delay + 1)),
            second
        )
    }

    private func makeInterventionApproval(id: String, autoApprove: Bool = false) -> SessionState {
        var session = SessionState(
            sessionId: "intervention-only-approval", cwd: "/tmp/project",
            autoApprovePermissions: autoApprove, phase: .processing
        )
        session.intervention = SessionIntervention(
            id: id, kind: .approval, title: "Approve command", message: "pwd",
            options: [], questions: [], supportsSessionScope: false, metadata: [:]
        )
        return session
    }

    func testSuppressedApprovalIsConsumedAndOnlyANewRequestCanAutoOpen() {
        var tracker = SessionManualAttentionTracker()
        let approval = makeApprovalSession(toolUseId: "tool-1")

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [approval], suppressAutoOpen: true))
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [approval], suppressAutoOpen: false))

        let nextApproval = makeApprovalSession(toolUseId: "tool-2")
        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [nextApproval], suppressAutoOpen: false),
            nextApproval
        )
    }

    func testSuppressedQuestionIsConsumedAndOnlyANewQuestionCanAutoOpen() {
        var tracker = SessionManualAttentionTracker()
        let question = SessionState(
            sessionId: "terminal-routed-question",
            cwd: "/tmp/project",
            suppressInAppPromptControls: true,
            phase: .waitingForInput
        )

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [question], suppressAutoOpen: true))
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [question], suppressAutoOpen: false))
        XCTAssertNil(tracker.consumeNewAttentionSession(from: []))
        XCTAssertEqual(tracker.consumeNewAttentionSession(from: [question]), question)
    }

    func testSuppressedDelayedApprovalIsConsumedWhenDelayExpires() throws {
        var tracker = SessionManualAttentionTracker()
        let now = Date()
        let approval = makeApprovalSession(toolUseId: "tool-auto", autoApprovePermissions: true)

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [approval], suppressAutoOpen: true, now: now))
        let readyAt = try XCTUnwrap(tracker.nextDelayedAttentionDate(from: [approval], now: now))
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [approval], suppressAutoOpen: true, now: readyAt))
        XCTAssertNil(tracker.nextDelayedAttentionDate(from: [approval], now: readyAt))
        XCTAssertNil(tracker.consumeNewAttentionSession(
            from: [approval],
            suppressAutoOpen: false,
            now: readyAt.addingTimeInterval(30)
        ))
    }

    func testTerminalRoutedPromptTriggersAttentionNotification() {
        var tracker = SessionManualAttentionTracker()
        let session = SessionState(
            sessionId: "terminal-routed-question",
            cwd: "/tmp/project",
            suppressInAppPromptControls: true,
            phase: .waitingForInput
        )

        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [session])?.stableId,
            session.stableId
        )
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [session]))
    }

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

    func testAutoApproveApprovalNotificationIsDelayed() throws {
        var tracker = SessionManualAttentionTracker()
        let now = Date()
        let session = makeApprovalSession(toolUseId: "tool-auto", autoApprovePermissions: true)

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [session], now: now))

        let readyAt = try XCTUnwrap(tracker.nextDelayedAttentionDate(from: [session], now: now))
        XCTAssertEqual(
            readyAt.timeIntervalSince(now),
            SessionManualAttentionTracker.autoApproveApprovalNotificationDelay,
            accuracy: 0.001
        )
        XCTAssertNil(
            tracker.consumeNewAttentionSession(
                from: [session],
                now: now.addingTimeInterval(
                    SessionManualAttentionTracker.autoApproveApprovalNotificationDelay - 0.01
                )
            )
        )
    }

    func testAutoApproveApprovalNotificationSurfacesIfStillPendingAfterDelay() {
        var tracker = SessionManualAttentionTracker()
        let now = Date()
        let session = makeApprovalSession(toolUseId: "tool-auto", autoApprovePermissions: true)

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [session], now: now))

        XCTAssertEqual(
            tracker.consumeNewAttentionSession(
                from: [session],
                now: now.addingTimeInterval(SessionManualAttentionTracker.autoApproveApprovalNotificationDelay)
            )?.stableId,
            session.stableId
        )
        XCTAssertNil(
            tracker.consumeNewAttentionSession(
                from: [session],
                now: now.addingTimeInterval(SessionManualAttentionTracker.autoApproveApprovalNotificationDelay + 0.1)
            )
        )
    }

    func testResolvedAutoApproveApprovalDoesNotSurfaceAfterDelay() {
        var tracker = SessionManualAttentionTracker()
        let now = Date()
        let session = makeApprovalSession(toolUseId: "tool-auto", autoApprovePermissions: true)
        let resolved = SessionState(
            sessionId: session.sessionId,
            cwd: session.cwd,
            provider: session.provider,
            clientInfo: session.clientInfo,
            autoApprovePermissions: true,
            phase: .processing
        )

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [session], now: now))
        XCTAssertNil(
            tracker.consumeNewAttentionSession(
                from: [resolved],
                now: now.addingTimeInterval(SessionManualAttentionTracker.autoApproveApprovalNotificationDelay)
            )
        )
        XCTAssertNil(tracker.nextDelayedAttentionDate(from: [resolved], now: now))
    }

    func testDisablingAutoApproveDuringDelaySurfacesApprovalImmediately() {
        var tracker = SessionManualAttentionTracker()
        let now = Date()
        let delayed = makeApprovalSession(toolUseId: "tool-auto", autoApprovePermissions: true)
        let manual = makeApprovalSession(toolUseId: "tool-auto", autoApprovePermissions: false)

        XCTAssertNil(tracker.consumeNewAttentionSession(from: [delayed], now: now))
        XCTAssertEqual(
            tracker.consumeNewAttentionSession(
                from: [manual],
                now: now.addingTimeInterval(0.1)
            )?.stableId,
            manual.stableId
        )
        XCTAssertNil(tracker.nextDelayedAttentionDate(from: [manual], now: now))
    }

    private func makeApprovalSession(
        toolUseId: String,
        autoApprovePermissions: Bool = false
    ) -> SessionState {
        SessionState(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI"
            ),
            autoApprovePermissions: autoApprovePermissions,
            phase: .waitingForApproval(PermissionContext(
                toolUseId: toolUseId,
                toolName: "ExitPlanMode",
                toolInput: ["plan": AnyCodable("Plan text")],
                receivedAt: Date()
            ))
        )
    }
}
