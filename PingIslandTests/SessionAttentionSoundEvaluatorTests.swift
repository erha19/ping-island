import XCTest
@testable import Ping_Island

/// Tests for the always-allow guard introduced by `fix-claude-sound-triggers`.
/// The evaluator decides whether a session contributes to the
/// `attentionRequired` notification-sound edge set used by `NotchView` and
/// `DetachedIslandWindowController`.
final class SessionAttentionSoundEvaluatorTests: XCTestCase {

    func testSessionWithApprovalInterventionContributesByDefault() {
        let session = makeSession(
            autoApprovePermissions: false,
            phase: .processing,
            intervention: makeApprovalIntervention()
        )
        // Note: needsApprovalResponse requires phase.isWaitingForApproval OR
        // intervention.kind == .approval. The intervention satisfies the latter.
        XCTAssertTrue(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session)
        )
    }

    func testWaitingForInputWithInterventionContributes() {
        let session = makeSession(
            autoApprovePermissions: false,
            phase: .waitingForInput,
            intervention: makeQuestionIntervention()
        )
        XCTAssertTrue(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session)
        )
    }

    func testAutoApproveSuppressesContributionEvenWithApprovalIntervention() {
        // The bug: a PermissionRequest hook briefly inserts an approval
        // intervention before SessionMonitor auto-approves it. Without the
        // guard, the phase-edge detector picks this up and chimes.
        let session = makeSession(
            autoApprovePermissions: true,
            phase: .processing,
            intervention: makeApprovalIntervention()
        )
        XCTAssertFalse(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session),
            "Always-allow sessions must NOT contribute to the attentionRequired sound edge"
        )
    }

    func testAutoApproveSuppressesContributionEvenInWaitingForApprovalPhase() {
        let session = makeSession(
            autoApprovePermissions: true,
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "tool-1",
                toolName: "Bash",
                toolInput: nil,
                receivedAt: Date()
            )),
            intervention: nil
        )
        XCTAssertFalse(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session)
        )
    }

    func testTogglingAutoApproveOffRestoresContribution() {
        // Regression for the toggle-off path: once the user disables
        // always-allow, future PermissionRequests must once again be
        // eligible for the attention sound.
        let armed = makeSession(
            autoApprovePermissions: true,
            phase: .processing,
            intervention: makeApprovalIntervention()
        )
        XCTAssertFalse(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(armed)
        )

        var disarmed = armed
        disarmed.autoApprovePermissions = false

        XCTAssertTrue(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(disarmed),
            "After disabling always-allow, the same intervention must contribute again"
        )
    }

    func testIdleSessionWithoutInterventionDoesNotContribute() {
        let session = makeSession(
            autoApprovePermissions: false,
            phase: .idle,
            intervention: nil
        )
        XCTAssertFalse(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session)
        )
    }

    // MARK: - Helpers

    private func makeSession(
        autoApprovePermissions: Bool,
        phase: SessionPhase,
        intervention: SessionIntervention?
    ) -> SessionState {
        SessionState(
            sessionId: "attention-sound-test-\(UUID().uuidString)",
            cwd: "/tmp/project",
            intervention: intervention,
            autoApprovePermissions: autoApprovePermissions,
            phase: phase
        )
    }

    private func makeApprovalIntervention() -> SessionIntervention {
        SessionIntervention(
            id: "intervention-approval",
            kind: .approval,
            title: "Approve Bash",
            message: "ls",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: ["toolName": "Bash"]
        )
    }

    private func makeQuestionIntervention() -> SessionIntervention {
        SessionIntervention(
            id: "intervention-question",
            kind: .question,
            title: "Pick one",
            message: "Choose A or B",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )
    }
}
