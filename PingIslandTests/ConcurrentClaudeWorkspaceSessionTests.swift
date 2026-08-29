import XCTest
@testable import Ping_Island

/// Store-level coverage for several Claude Code sessions sharing one project
/// directory. Restart leftovers must be cleaned up, but sessions whose process is
/// still running must survive: reporting activity is not evidence that a sibling
/// has been replaced.
final class ConcurrentClaudeWorkspaceSessionTests: XCTestCase {

    private let clientInfo = SessionClientInfo(kind: .claudeCode, name: "Claude Code")

    private func promptEvent(sessionId: String, cwd: String, pid: Int?, message: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: clientInfo,
            pid: pid,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: message
        )
    }

    func testConcurrentLiveSessionsInSameWorkspaceRemainIndependent() async {
        let workspace = "/tmp/ping-island-concurrent-\(UUID().uuidString)"
        let firstSessionId = "claude-concurrent-first-\(UUID().uuidString)"
        let secondSessionId = "claude-concurrent-second-\(UUID().uuidString)"
        // The test process itself is a PID that is unambiguously alive.
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        let store = SessionStore.shared

        await store.process(.hookReceived(promptEvent(
            sessionId: firstSessionId,
            cwd: workspace,
            pid: livePid,
            message: "First concurrent request"
        )))
        await store.process(.hookReceived(promptEvent(
            sessionId: secondSessionId,
            cwd: workspace,
            pid: livePid,
            message: "Second concurrent request"
        )))

        let first = await store.session(for: firstSessionId)
        let second = await store.session(for: secondSessionId)
        XCTAssertNotNil(
            first,
            "A running Claude session must not be archived because another session started in the same directory"
        )
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.latestHookMessage, "First concurrent request")
        XCTAssertEqual(second?.latestHookMessage, "Second concurrent request")

        await store.process(.sessionArchived(sessionId: firstSessionId))
        await store.process(.sessionArchived(sessionId: secondSessionId))
    }

    func testRestartLeftoverWithoutLiveProcessIsStillArchived() async {
        let workspace = "/tmp/ping-island-restart-\(UUID().uuidString)"
        let staleSessionId = "claude-stale-\(UUID().uuidString)"
        let restartedSessionId = "claude-restarted-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(promptEvent(
            sessionId: staleSessionId,
            cwd: workspace,
            pid: nil,
            message: "Before the restart"
        )))
        await store.process(.hookReceived(promptEvent(
            sessionId: restartedSessionId,
            cwd: workspace,
            pid: nil,
            message: "After the restart"
        )))

        let stale = await store.session(for: staleSessionId)
        let restarted = await store.session(for: restartedSessionId)
        XCTAssertNil(
            stale,
            "A leftover session with no live process should still make way for the session that replaced it"
        )
        XCTAssertNotNil(restarted)

        await store.process(.sessionArchived(sessionId: restartedSessionId))
    }
}
