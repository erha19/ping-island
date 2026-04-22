import XCTest
@testable import Ping_Island

final class IslandExpandedRouteResolverTests: XCTestCase {
    func testClickResolvesToSessionList() {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .click,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing)]
        )

        XCTAssertEqual(route, .sessionList)
    }

    func testHoverWithoutManualAttentionResolvesToHoverDashboard() {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .hover,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing)]
        )

        XCTAssertEqual(route, .hoverDashboard)
    }

    func testHoverWithManualAttentionResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .hover,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing), attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testDockedNotificationWithCompletionResolvesToCompletionNotification() {
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .instances,
            sessions: [completed],
            activeCompletionNotification: notification
        )

        XCTAssertEqual(route, .completionNotification(notification))
    }

    func testFloatingNotificationWithApprovalResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: .notification,
            contentType: .instances,
            sessions: [attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testFloatingNotificationWithCompletionResolvesToCompletionNotification() {
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        let route = IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: .notification,
            contentType: .instances,
            sessions: [completed],
            activeCompletionNotification: notification
        )

        XCTAssertEqual(route, .completionNotification(notification))
    }

    private func makeSession(
        id: String,
        phase: SessionPhase,
        intervention: SessionIntervention? = nil
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            intervention: intervention,
            phase: phase
        )
    }

    private func makeIntervention(
        id: String,
        kind: SessionInterventionKind,
        message: String
    ) -> SessionIntervention {
        SessionIntervention(
            id: id,
            kind: kind,
            title: message,
            message: message,
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )
    }
}
