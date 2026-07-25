import XCTest
@testable import Ping_Island

final class StuckActiveSessionRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testLivePidStuckProcessingWithoutToolEvidenceDemotesAfterTimeout() {
        let session = makeClaudeSession(
            phase: .processing,
            pid: 12_345,
            lastActivity: now.addingTimeInterval(-StuckActiveSessionRecovery.liveProcessIdleTimeout - 1),
            chatItems: [
                ChatHistoryItem(
                    id: "tool-1",
                    type: .toolCall(ToolCallItem(
                        name: "Shell",
                        input: ["command": "git status"],
                        status: .success,
                        result: "ok",
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: now.addingTimeInterval(-90)
                )
            ]
        )

        let decision = StuckActiveSessionRecovery.decision(
            for: session,
            now: now,
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(decision, .demoteToWaitingForInput)
    }

    func testLivePidKeepsProcessingWhileToolStillRunning() {
        let session = makeClaudeSession(
            phase: .processing,
            pid: 12_345,
            lastActivity: now.addingTimeInterval(-StuckActiveSessionRecovery.liveProcessIdleTimeout - 1),
            chatItems: [
                ChatHistoryItem(
                    id: "tool-1",
                    type: .toolCall(ToolCallItem(
                        name: "Shell",
                        input: ["command": "sleep 999"],
                        status: .running,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: now.addingTimeInterval(-120)
                )
            ]
        )

        let decision = StuckActiveSessionRecovery.decision(
            for: session,
            now: now,
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(decision, .keep)
    }

    func testLivePidKeepsProcessingBeforeTimeout() {
        let session = makeClaudeSession(
            phase: .processing,
            pid: 12_345,
            lastActivity: now.addingTimeInterval(-30),
            chatItems: []
        )

        let decision = StuckActiveSessionRecovery.decision(
            for: session,
            now: now,
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(decision, .keep)
    }

    func testDeadPidEndsSession() {
        let session = makeClaudeSession(
            phase: .processing,
            pid: 12_345,
            lastActivity: now.addingTimeInterval(-30),
            chatItems: []
        )

        let decision = StuckActiveSessionRecovery.decision(
            for: session,
            now: now,
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(decision, .endSession)
    }

    func testMissingPidDemotesAfterShortTimeoutWithoutEvidence() {
        let session = makeClaudeSession(
            phase: .processing,
            pid: nil,
            lastActivity: now.addingTimeInterval(-StuckActiveSessionRecovery.missingProcessIdleTimeout - 1),
            chatItems: []
        )

        let decision = StuckActiveSessionRecovery.decision(
            for: session,
            now: now,
            isProcessAlive: { _ in true }
        )

        XCTAssertEqual(decision, .demoteToWaitingForInput)
    }

    private func makeClaudeSession(
        phase: SessionPhase,
        pid: Int?,
        lastActivity: Date,
        chatItems: [ChatHistoryItem]
    ) -> SessionState {
        SessionState(
            sessionId: "stuck-\(UUID().uuidString)",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "cursor",
                name: "Cursor",
                bundleIdentifier: "com.todesktop.230313mzl4w4u92"
            ),
            pid: pid,
            phase: phase,
            chatItems: chatItems,
            lastActivity: lastActivity
        )
    }
}
