import XCTest
@testable import Ping_Island

/// Cover for hook sessions that no process can be asked about.
///
/// A CLI session always resolves itself — `SessionEnd` on exit, or a dead pid the
/// liveness sweep reaps. Desktop hook clients offer neither: one long-lived kernel
/// serves every conversation, so no pid ever dies. A trace from the Kimi app shows a
/// conversation still tracked 31 hours after its last hook, permanently marked as
/// waiting on the user. Wall-clock is the only evidence left.
final class SessionStoreIdleHookExpiryTests: XCTestCase {
    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        pid: Int? = nil,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/ping-island-idle-expiry",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo.default(for: .claude),
            pid: pid,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    func testSessionWithNoProcessEndsAfterTheIdleWindow() async throws {
        let sessionId = "idle-expiry-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "Stop", status: "waiting_for_input"
        )))

        let liveSession = await store.session(for: sessionId)
        let live = try XCTUnwrap(liveSession)
        XCTAssertEqual(live.phase, .waitingForInput)
        let lastActivity = live.lastActivity

        await store.expireStaleHookSessions(now: Date().addingTimeInterval(3 * 60 * 60))

        let expiredSession = await store.session(for: sessionId)
        let expired = try XCTUnwrap(expiredSession)
        XCTAssertEqual(expired.phase, .ended)
        // The completion notification policy gates on how recently a session was
        // active. Stamping `lastActivity` here would announce hours-old sessions as
        // freshly complete the moment the sweep ran.
        XCTAssertEqual(
            expired.lastActivity.timeIntervalSince1970,
            lastActivity.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testSessionInsideTheIdleWindowSurvives() async throws {
        let sessionId = "idle-expiry-recent-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "Stop", status: "waiting_for_input"
        )))

        await store.expireStaleHookSessions(now: Date().addingTimeInterval(60 * 60))

        let current = await store.session(for: sessionId)
        let session = try XCTUnwrap(current)
        XCTAssertEqual(session.phase, .waitingForInput)
    }

    /// A live pid is checkable evidence; that case belongs to the liveness sweep,
    /// which can actually prove the process is gone.
    func testSessionWithALivePidIsLeftToTheLivenessSweep() async throws {
        let sessionId = "idle-expiry-pid-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input",
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        )))

        await store.expireStaleHookSessions(now: Date().addingTimeInterval(3 * 60 * 60))

        let current = await store.session(for: sessionId)
        let session = try XCTUnwrap(current)
        XCTAssertEqual(session.phase, .waitingForInput)
    }

    /// A bridge blocked on an approval the user never answered is proof of a live
    /// client, however long it has been waiting.
    func testSessionBlockedOnAnApprovalIsNotExpired() async throws {
        let sessionId = "idle-expiry-approval-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId,
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolUseId: "tool-idle-expiry"
        )))

        let pendingSession = await store.session(for: sessionId)
        let pending = try XCTUnwrap(pendingSession)
        XCTAssertTrue(pending.phase.isWaitingForApproval)

        await store.expireStaleHookSessions(now: Date().addingTimeInterval(3 * 60 * 60))

        let current = await store.session(for: sessionId)
        let session = try XCTUnwrap(current)
        XCTAssertTrue(session.phase.isWaitingForApproval)
    }
}
