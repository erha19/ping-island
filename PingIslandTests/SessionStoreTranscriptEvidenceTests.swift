import XCTest
@testable import Ping_Island

final class SessionStoreTranscriptEvidenceTests: XCTestCase {
    func testIdleRefreshDoesNotRenewExpiredExecutionEvidence() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = SessionState(
            sessionId: "idle-evidence",
            cwd: "/tmp/idle-evidence",
            provider: .claude,
            phase: .processing,
            chatItems: [ChatHistoryItem(
                id: "tool",
                type: .toolCall(ToolCallItem(
                    name: "Bash", input: [:], status: .running,
                    result: nil, structuredResult: nil, subagentTools: []
                )),
                timestamp: now.addingTimeInterval(-3600)
            )],
            lastActivity: now
        )
        for (age, expected) in [(60.0, true), (1801.0, false)] {
            let preserved = await SessionStore.shared.shouldPreserveActivePhaseDuringApparentIdle(
                session: session,
                incomingPhase: .idle,
                referenceDate: now,
                previousLastActivity: now.addingTimeInterval(-age)
            )
            XCTAssertEqual(preserved, expected, "Execution evidence age: \(age)")
        }
    }

    func testStandaloneTranscriptToolResultIsDeliveredWithoutNewMessages() async throws {
        let id = "tool-result-only-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")
        let store = SessionStore.shared
        await store.process(.hookReceived(HookEvent(
            sessionId: id, cwd: directory.path, event: "PreToolUse", status: "running_tool",
            provider: .claude, clientInfo: .default(for: .claude), pid: nil, tty: nil,
            tool: "Bash", toolInput: [:], toolUseId: "tool", notificationType: nil, message: nil
        )))
        try Data(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"done"}]}}"#.utf8)
            .write(to: transcript)
        let result = await ConversationParser.shared.parseIncremental(
            sessionId: id, cwd: directory.path, explicitFilePath: transcript.path
        )
        XCTAssertTrue(result.newMessages.isEmpty)
        XCTAssertEqual(result.completedToolIds, ["tool"])
        let pending = await store.hasPendingCompletedToolResult(
            sessionId: id, completedToolIds: result.completedToolIds
        )
        XCTAssertTrue(pending, "Pollers must deliver result-only deltas")
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: id, cwd: directory.path, messages: result.newMessages, isIncremental: true,
            completedToolIds: result.completedToolIds, toolResults: result.toolResults,
            structuredResults: result.structuredResults
        )))
        let delivered = await store.session(for: id)
        guard case .toolCall(let tool) = delivered?.chatItems.first?.type else {
            XCTFail("Expected tracked tool")
            await store.process(.sessionArchived(sessionId: id))
            return
        }
        XCTAssertEqual(tool.status, .success)
        let stillPending = await store.hasPendingCompletedToolResult(
            sessionId: id, completedToolIds: result.completedToolIds
        )
        XCTAssertFalse(stillPending, "Unchanged polls must not repeatedly publish completed results")
        await store.process(.sessionArchived(sessionId: id))
        await ConversationParser.shared.resetState(for: id)
    }
}
