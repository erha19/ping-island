import XCTest
@testable import Ping_Island

/// Coverage for the rule that decides when a newer session may take another
/// session's place in the same workspace.
///
/// The rule used to be "keep the most recently active session per provider + cwd",
/// which collapsed two Claude CLI sessions running side by side in one directory
/// into a single row. Because the surviving row then changed on every hook event,
/// the primary list flipped between the two sessions and the notification-sound
/// edges read each flip as a session starting work.
final class SameWorkspaceSessionSupersessionTests: XCTestCase {

    private let workspace = "/tmp/ping-island-workspace"
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        id: String,
        cwd: String? = nil,
        clientInfo: SessionClientInfo? = nil,
        provider: SessionProvider = .claude,
        ingress: SessionIngress = .hookBridge,
        pid: Int? = nil,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        activityOffset: TimeInterval
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: cwd ?? workspace,
            provider: provider,
            clientInfo: clientInfo ?? SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            ingress: ingress,
            pid: pid,
            phase: phase,
            chatItems: chatItems,
            lastActivity: reference.addingTimeInterval(activityOffset)
        )
    }

    private func runningToolItem() -> ChatHistoryItem {
        ChatHistoryItem(
            id: "tool-1",
            type: .toolCall(ToolCallItem(
                name: "Bash",
                input: [:],
                status: .running,
                result: nil,
                structuredResult: nil,
                subagentTools: []
            )),
            timestamp: reference
        )
    }

    private var qwenClient: SessionClientInfo {
        SessionClientInfo(
            kind: .custom,
            profileID: "qwen-code",
            name: "Qwen Code",
            origin: "cli",
            originator: "Qwen Code",
            threadSource: "qwen-code-hooks"
        )
    }

    // MARK: - Concurrent sessions

    func testTwoLiveSessionsInOneDirectoryBothStayVisible() {
        let older = session(id: "older", pid: 101, phase: .processing, activityOffset: 0)
        let newer = session(id: "newer", pid: 102, phase: .processing, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [older, newer],
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(
            visible.map(\.sessionId),
            ["older", "newer"],
            "Two Claude instances running in the same directory are a supported setup and must both stay visible"
        )
    }

    func testLiveSessionSurvivesEvenWhenSiblingKeepsReportingActivity() {
        var older = session(id: "older", pid: 101, phase: .processing, activityOffset: 0)
        let newer = session(id: "newer", pid: 102, phase: .processing, activityOffset: 5)

        // Whichever session reported last must not change the other's visibility.
        for offset in stride(from: 10.0, through: 40.0, by: 10.0) {
            older.lastActivity = reference.addingTimeInterval(offset)
            let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
                from: [older, newer],
                isProcessAlive: { _ in true }
            )
            XCTAssertEqual(Set(visible.map(\.sessionId)), ["older", "newer"])
        }
    }

    func testConcurrentQwenSessionsAreNeverCollapsed() {
        let older = session(id: "qwen-older", clientInfo: qwenClient, phase: .processing, activityOffset: 0)
        let newer = session(id: "qwen-newer", clientInfo: qwenClient, phase: .processing, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [older, newer],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(
            Set(visible.map(\.sessionId)),
            ["qwen-older", "qwen-newer"],
            "Qwen hooks carry no CLI PID, so liveness cannot be proven; their stable session IDs already allow several sessions per workspace"
        )
    }

    // MARK: - Restarted / orphaned sessions

    func testOrphanedSessionIsSupersededByNewerSibling() {
        let orphan = session(id: "orphan", pid: 101, phase: .idle, activityOffset: 0)
        let restarted = session(id: "restarted", pid: 102, phase: .processing, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [orphan, restarted],
            isProcessAlive: { pid in pid == 102 }
        )

        XCTAssertEqual(
            visible.map(\.sessionId),
            ["restarted"],
            "A session whose process is gone should not linger next to the session that replaced it"
        )
    }

    func testSessionWithoutPidIsSupersededByNewerSibling() {
        let orphan = session(id: "orphan", phase: .idle, activityOffset: 0)
        let restarted = session(id: "restarted", pid: 102, phase: .processing, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [orphan, restarted],
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(visible.map(\.sessionId), ["restarted"])
    }

    // MARK: - Sessions that stand on their own terms

    func testRunningToolKeepsAnOtherwiseOrphanedSessionVisible() {
        let working = session(
            id: "working",
            pid: 101,
            phase: .processing,
            chatItems: [runningToolItem()],
            activityOffset: 0
        )
        let newer = session(id: "newer", pid: 102, phase: .processing, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [working, newer],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(Set(visible.map(\.sessionId)), ["working", "newer"])
    }

    func testSessionAwaitingApprovalIsNeverSuperseded() {
        let waiting = session(
            id: "waiting",
            pid: 101,
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "tool-1",
                toolName: "Bash",
                toolInput: nil,
                receivedAt: reference
            )),
            activityOffset: 0
        )
        let newer = session(id: "newer", pid: 102, phase: .processing, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [waiting, newer],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(Set(visible.map(\.sessionId)), ["waiting", "newer"])
    }

    func testEndedSessionStaysVisibleUntilArchived() {
        let ended = session(id: "ended", pid: 101, phase: .ended, activityOffset: 0)
        let newer = session(id: "newer", pid: 102, phase: .processing, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [ended, newer],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(
            Set(visible.map(\.sessionId)),
            ["ended", "newer"],
            "Ended sessions remain in the list until the user archives them"
        )
    }

    func testNewestSessionIsAlwaysKept() {
        let older = session(id: "older", phase: .idle, activityOffset: 0)
        let newest = session(id: "newest", phase: .idle, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [older, newest],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(visible.map(\.sessionId), ["newest"])
    }

    func testSessionsWithIdenticalActivityAreBothKept() {
        let first = session(id: "first", phase: .idle, activityOffset: 0)
        let second = session(id: "second", phase: .idle, activityOffset: 0)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [first, second],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(Set(visible.map(\.sessionId)), ["first", "second"])
    }

    // MARK: - Scope of the rule

    func testDifferentDirectoriesNeverCompete() {
        let here = session(id: "here", phase: .idle, activityOffset: 0)
        let elsewhere = session(id: "elsewhere", cwd: "/tmp/other-workspace", phase: .idle, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [here, elsewhere],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(Set(visible.map(\.sessionId)), ["here", "elsewhere"])
    }

    func testCodexSessionsAreOutOfScope() {
        let older = session(id: "codex-older", provider: .codex, phase: .idle, activityOffset: 0)
        let newer = session(id: "codex-newer", provider: .codex, phase: .idle, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [older, newer],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(Set(visible.map(\.sessionId)), ["codex-older", "codex-newer"])
    }

    func testSessionsWithoutWorkspaceAreOutOfScope() {
        let older = session(id: "older", cwd: "", phase: .idle, activityOffset: 0)
        let newer = session(id: "newer", cwd: "", phase: .idle, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [older, newer],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(Set(visible.map(\.sessionId)), ["older", "newer"])
    }

    func testNativeRuntimeSessionsAreOutOfScope() {
        let older = session(id: "older", ingress: .nativeRuntime, phase: .idle, activityOffset: 0)
        let newer = session(id: "newer", ingress: .nativeRuntime, phase: .idle, activityOffset: 5)

        let visible = SameWorkspaceSessionSupersession.removingSupersededSessions(
            from: [older, newer],
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(Set(visible.map(\.sessionId)), ["older", "newer"])
    }

    // MARK: - Process liveness

    func testLivenessTreatsInvalidPidsAsDead() {
        XCTAssertFalse(SessionProcessLiveness.isAlive(0))
        XCTAssertFalse(SessionProcessLiveness.isAlive(-1))
    }

    func testLivenessRecognizesTheRunningTestProcess() {
        XCTAssertTrue(SessionProcessLiveness.isAlive(Int(ProcessInfo.processInfo.processIdentifier)))
    }
}
