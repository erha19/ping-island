import XCTest
@testable import Ping_Island

/// Regression cover for sessions latching into "运行中" after they had finished.
///
/// Replayed from a real trace: a session's `Stop` landed and ended the turn, then
/// a trailing `SubagentStop` — the child winding down after the parent — dragged
/// the parent back into `processing`. Nothing further was ever sent for that
/// session, so the row stayed "working" indefinitely.
final class SessionStoreSubagentStopTests: XCTestCase {
    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/ping-island-subagent",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo.default(for: .claude),
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    func testTrailingSubagentStopDoesNotReviveAFinishedSession() async throws {
        let sessionId = "subagent-stop-trailing-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "UserPromptSubmit", status: "processing"
        )))
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "Stop", status: "waiting_for_input"
        )))

        let finishedSession = await store.session(for: sessionId)
        let finished = try XCTUnwrap(finishedSession)
        XCTAssertEqual(finished.phase, .waitingForInput)

        // The bridge reports SubagentStop as `running_tool`, because from the
        // parent's point of view a Task tool was in flight. That must not
        // reopen a turn the parent already closed.
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "SubagentStop", status: "running_tool"
        )))

        let revivedSession = await store.session(for: sessionId)
        let afterSubagentStop = try XCTUnwrap(revivedSession)
        XCTAssertEqual(afterSubagentStop.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSubagentStopDoesNotCreateASessionThatIsNoLongerTracked() async throws {
        let sessionId = "subagent-stop-orphan-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "SubagentStop", status: "running_tool"
        )))

        let orphan = await store.session(for: sessionId)
        XCTAssertNil(
            orphan,
            "SubagentStop describes a child; with no parent tracked it has nothing to attach to"
        )
    }

    func testSubagentStartStillCreatesNothingButLeavesATrackedParentWorking() async throws {
        let sessionId = "subagent-start-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "SubagentStart", status: "running_tool"
        )))
        let unstartedParent = await store.session(for: sessionId)
        XCTAssertNil(unstartedParent)

        // With a parent present, SubagentStart remains authoritative: a session
        // that just spawned a child is demonstrably working.
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "UserPromptSubmit", status: "processing"
        )))
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId, event: "SubagentStart", status: "running_tool"
        )))

        let startedSession = await store.session(for: sessionId)
        let session = try XCTUnwrap(startedSession)
        XCTAssertEqual(session.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSubagentLifecycleEventsAreNamedExplicitly() {
        XCTAssertTrue(SessionStore.isSubagentLifecycleEvent("SubagentStart"))
        XCTAssertTrue(SessionStore.isSubagentLifecycleEvent("SubagentStop"))
        XCTAssertFalse(SessionStore.isSubagentLifecycleEvent("Stop"))
        XCTAssertFalse(SessionStore.isSubagentLifecycleEvent("SessionEnd"))
        XCTAssertFalse(SessionStore.isSubagentLifecycleEvent("PostToolUse"))
    }
}
