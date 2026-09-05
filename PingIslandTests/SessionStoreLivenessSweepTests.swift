import Darwin
import Foundation
import XCTest
@testable import Ping_Island

/// Tests for the periodic liveness sweep introduced by
/// `fix-claude-sound-triggers`. The sweep removes sessions whose tracked pid
/// is no longer alive (Ctrl-C, OOM, terminal closed) and garbage-collects
/// sessions already in `.ended` phase.
final class SessionStoreLivenessSweepTests: XCTestCase {

    func testSessionEndDuringTranscriptEnrichmentPreservesFinalContent() async throws {
        let id = "liveness-enrichment-end-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        let captured = await store.session(for: id)
        let original = try XCTUnwrap(captured)
        var enriched = original
        enriched.chatItems.append(ChatHistoryItem(
            id: "enriched-final", type: .assistant("Final subagent result"), timestamp: Date()
        ))

        // A Task-result parser await allows SessionEnd to land between capture
        // and commit; reproduce that ordering without a timing-dependent sleep.
        await store.process(.sessionEnded(sessionId: id))
        let ended = await store.session(for: id)
        let committed = await store.commitTranscriptUpdate(enriched, basedOn: original)
        XCTAssertEqual(committed?.phase, .ended)
        XCTAssertEqual(committed?.lastActivity, ended?.lastActivity)
        XCTAssertTrue(committed?.chatItems.contains(where: { $0.id == "enriched-final" }) == true)
        await store.process(.sessionArchived(sessionId: id))
    }

    func testArchiveDuringTranscriptEnrichmentDropsStaleUpdate() async throws {
        let id = "liveness-enrichment-archive-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        let captured = await store.session(for: id)
        let original = try XCTUnwrap(captured)
        await store.process(.sessionArchived(sessionId: id))
        let committed = await store.commitTranscriptUpdate(original, basedOn: original)
        XCTAssertNil(committed)
        let current = await store.session(for: id)
        XCTAssertNil(current)
    }

    func testSessionEndDuringTranscriptReadCannotBeOverwritten() async throws {
        let id = "liveness-read-end-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        let payload = FileUpdatePayload(
            sessionId: id, cwd: "/tmp/project",
            messages: [ChatMessage(
                id: "final-reply", role: .assistant, timestamp: Date(), content: [.text("Finished")]
            )],
            isIncremental: true, completedToolIds: [], toolResults: [:], structuredResults: [:]
        )
        // Deterministically interleave SessionEnd at the parser await boundary.
        await store.processFileUpdate(payload, conversationInfoLoader: {
            await store.process(.sessionEnded(sessionId: id))
            return ConversationInfo(
                summary: nil, lastMessage: "Finished", lastMessageRole: "assistant",
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )
        })
        let session = await store.session(for: id)
        XCTAssertEqual(session?.phase, .ended)
        XCTAssertTrue(session?.chatItems.contains(where: { $0.id == "final-reply-text-0" }) == true)
        await store.sweepDeadOrEndedSessions()
        let reaped = await store.session(for: id)
        XCTAssertNil(reaped)
    }

    func testArchiveDuringTranscriptReadCannotRecreateSession() async {
        let id = "liveness-read-archive-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(sessionId: id, pid: nil)))
        await store.processFileUpdate(FileUpdatePayload(
            sessionId: id, cwd: "/tmp/project", messages: [], isIncremental: true,
            completedToolIds: [], toolResults: [:], structuredResults: [:]
        ), conversationInfoLoader: {
            await store.process(.sessionArchived(sessionId: id))
            return ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )
        })
        let archived = await store.session(for: id)
        XCTAssertNil(archived)
    }

    func testSweepRemovesSessionWithDeadPid() async throws {
        // Spawn /usr/bin/true and wait for it to exit so we have a real pid
        // that is guaranteed dead at the moment we register the session.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPid = Int(process.processIdentifier)
        XCTAssertGreaterThan(deadPid, 0)
        XCTAssertTrue(
            Darwin.kill(pid_t(deadPid), 0) != 0 && errno == ESRCH,
            "Test setup precondition: spawned pid must be dead before the sweep runs"
        )

        let sessionId = "liveness-dead-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: deadPid
        )))

        let beforeSweep = await store.session(for: sessionId)
        XCTAssertNotNil(beforeSweep, "Session must exist before sweep")

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNil(afterSweep, "Session with dead pid must be removed by the sweep")
    }

    func testSweepRemovesEndedSession() async {
        let sessionId = "liveness-ended-\(UUID().uuidString)"
        let store = SessionStore.shared

        // Use a real SessionEnd hook to drive the session into `.ended` phase
        // (the only public way to invoke markSessionEnded).
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid()),
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid()),
            event: "SessionEnd",
            status: "ended"
        )))

        let beforeSweep = await store.session(for: sessionId)
        XCTAssertEqual(beforeSweep?.phase, .ended,
                       "Test setup precondition: session must reach .ended phase")

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNil(afterSweep, ".ended sessions must be garbage-collected by the sweep")
    }

    func testSweepLeavesSessionWithoutPidAlone() async {
        let sessionId = "liveness-nopid-\(UUID().uuidString)"
        let store = SessionStore.shared

        // pid: nil means we cannot assert the process is dead.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: nil
        )))

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNotNil(afterSweep,
                        "Sessions without a tracked pid must NOT be removed on liveness grounds")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSweepLeavesLiveSessionAlone() async {
        let sessionId = "liveness-live-\(UUID().uuidString)"
        let store = SessionStore.shared

        // getpid() is the test runner itself — guaranteed alive, phase != .ended.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid())
        )))

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNotNil(afterSweep,
                        "Live, non-ended sessions must be untouched by the sweep")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    // MARK: - Helpers

    private func makeClaudeEvent(
        sessionId: String,
        pid: Int?,
        event: String = "UserPromptSubmit",
        status: String = "processing"
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: pid,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }
}
