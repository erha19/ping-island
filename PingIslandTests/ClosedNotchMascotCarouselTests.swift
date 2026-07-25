import XCTest
@testable import Ping_Island

final class ClosedNotchMascotCarouselTests: XCTestCase {
    func testSessionsOrdersPromptAttentionBeforeActiveWork() {
        let now = Date()
        let active = SessionState(
            sessionId: "active",
            cwd: "/tmp/active",
            phase: .processing,
            lastActivity: now
        )
        let approval = SessionState(
            sessionId: "approval",
            cwd: "/tmp/approval",
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: now.addingTimeInterval(-10))
            ),
            lastActivity: now.addingTimeInterval(-10)
        )

        let sessions = ClosedNotchMascotCarousel.sessions(from: [active, approval])
        XCTAssertEqual(sessions.map(\.sessionId), ["approval", "active"])
    }

    func testSessionsIncludesMultipleActiveAgentsForRotation() {
        let now = Date()
        let first = SessionState(
            sessionId: "first",
            cwd: "/tmp/first",
            phase: .processing,
            lastActivity: now.addingTimeInterval(-5)
        )
        let second = SessionState(
            sessionId: "second",
            cwd: "/tmp/second",
            phase: .processing,
            lastActivity: now
        )
        let idle = SessionState(
            sessionId: "idle",
            cwd: "/tmp/idle",
            phase: .idle,
            lastActivity: now.addingTimeInterval(20)
        )

        let sessions = ClosedNotchMascotCarousel.sessions(from: [idle, first, second])
        XCTAssertEqual(sessions.map(\.sessionId), ["second", "first"])
    }

    func testIndexRotatesAcrossMultipleSessions() {
        let date = Date(timeIntervalSinceReferenceDate: 4.0) // 4 / 2 = tick 2
        XCTAssertEqual(ClosedNotchMascotCarousel.index(sessionCount: 3, at: date), 2)
        XCTAssertEqual(ClosedNotchMascotCarousel.index(sessionCount: 1, at: date), 0)
    }

    func testCurrentSessionCyclesBetweenWorkingAgents() {
        let now = Date()
        let first = SessionState(
            sessionId: "first",
            cwd: "/tmp/first",
            phase: .processing,
            lastActivity: now.addingTimeInterval(-5)
        )
        let second = SessionState(
            sessionId: "second",
            cwd: "/tmp/second",
            phase: .processing,
            lastActivity: now
        )
        let instances = [first, second]

        let firstSlot = Date(timeIntervalSinceReferenceDate: 0)
        let secondSlot = Date(timeIntervalSinceReferenceDate: ClosedNotchMascotCarousel.interval)

        XCTAssertEqual(
            ClosedNotchMascotCarousel.currentSession(from: instances, at: firstSlot)?.sessionId,
            "second"
        )
        XCTAssertEqual(
            ClosedNotchMascotCarousel.currentSession(from: instances, at: secondSlot)?.sessionId,
            "first"
        )
    }
}
