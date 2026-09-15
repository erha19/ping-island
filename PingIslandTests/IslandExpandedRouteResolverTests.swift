import XCTest
@testable import Ping_Island

final class IslandExpandedRouteResolverTests: XCTestCase {
    func testHoverPreviewRetainsConnectedCompletionStates() {
        let completed = [SessionPhase.waitingForInput, .idle, .ended].enumerated().map {
            makeSession(id: "completed-\($0.offset)", phase: $0.element)
        }
        XCTAssertEqual(
            Set(IslandExpandedRouteResolver.activePreviewSessions(from: completed).map(\.sessionId)),
            Set(completed.map(\.sessionId))
        )
        let disconnected = completed.map { session in
            var copy = session
            copy.connectionState = .disconnected
            return copy
        }
        XCTAssertTrue(IslandExpandedRouteResolver.activePreviewSessions(from: disconnected).isEmpty)
        var stale = makeSession(id: "stale", phase: .idle)
        stale.lastActivity = Date().addingTimeInterval(-24 * 60 * 60)
        XCTAssertTrue(IslandExpandedRouteResolver.activePreviewSessions(from: [stale]).isEmpty)
    }

    func testClickResolvesToSessionList() {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .click,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing)]
        )

        XCTAssertEqual(route, .sessionList)
    }

    func testClickWithManualAttentionResolvesToAttentionNotification() {
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
            surface: .docked,
            trigger: .click,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing), attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
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

    func testDockedNotificationWithApprovalResolvesToAttentionNotification() {
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
            surface: .docked,
            trigger: .notification,
            contentType: .instances,
            sessions: [attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testNotificationAttentionOverridesPreviouslyOpenChat() {
        let staleChat = makeSession(id: "stale-chat", phase: .processing)
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
            trigger: .notification,
            contentType: .chat(staleChat),
            sessions: [staleChat, attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
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
