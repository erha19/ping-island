import XCTest
@testable import Ping_Island

/// Regression cover for a finished session being dragged back into "运行中" by its
/// own transcript.
///
/// Replayed from a real trace: `Stop` moved the session to `waitingForInput` and
/// the island showed its completion card, then — 107ms later — the sync that same
/// hook had scheduled found the transcript unchanged, published the whole
/// conversation as a delta, and the historical prompts inside it read as "the user
/// started something". Nothing further is ever sent for a session whose turn has
/// ended, so the row stayed "working" until an unrelated session superseded it
/// three minutes later.
final class SessionStoreTranscriptReplayTests: XCTestCase {

    private let workspace = "/tmp/ping-island-transcript-replay"

    private func makeEvent(sessionId: String, event: String, status: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: workspace,
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo.default(for: .claude),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    private func payload(sessionId: String, messages: [ChatMessage]) -> FileUpdatePayload {
        FileUpdatePayload(
            sessionId: sessionId,
            cwd: workspace,
            messages: messages,
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:]
        )
    }

    private func message(id: String, role: ChatRole, at date: Date) -> ChatMessage {
        ChatMessage(id: id, role: role, timestamp: date, content: [.text("replayed \(id)")])
    }

    /// Drive a session to the state the trace captured: one turn asked and
    /// answered, the agent now waiting on the user.
    private func makeFinishedSession(_ sessionId: String) async throws -> SessionState {
        let store = SessionStore.shared
        await store.process(.hookReceived(
            makeEvent(sessionId: sessionId, event: "UserPromptSubmit", status: "processing")
        ))
        await store.process(.hookReceived(
            makeEvent(sessionId: sessionId, event: "Stop", status: "waiting_for_input")
        ))

        let finishedSession = await store.session(for: sessionId)
        let finished = try XCTUnwrap(finishedSession)
        XCTAssertEqual(finished.phase, .waitingForInput)
        return finished
    }

    func testReplayedTranscriptDoesNotReopenAFinishedTurn() async throws {
        let sessionId = "transcript-replay-\(UUID().uuidString)"
        let store = SessionStore.shared
        let finished = try await makeFinishedSession(sessionId)

        // The conversation as it stood when the turn ended: the session's own
        // prompts, all of them older than the `Stop` that closed the turn.
        let history = [
            message(id: "u1", role: .user, at: finished.lastActivity.addingTimeInterval(-600)),
            message(id: "u2", role: .user, at: finished.lastActivity.addingTimeInterval(-120)),
            message(id: "a1", role: .assistant, at: finished.lastActivity.addingTimeInterval(-1)),
        ]
        await store.process(.fileUpdated(payload(sessionId: sessionId, messages: history)))

        let replayedSession = await store.session(for: sessionId)
        let afterReplay = try XCTUnwrap(replayedSession)
        XCTAssertEqual(
            afterReplay.phase,
            .waitingForInput,
            "A replay carries the session's own history; it is not the user starting something"
        )

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    /// The signal still has to work: clients that report no `UserPromptSubmit`
    /// leave the transcript as the only evidence that a new turn began.
    func testNewUserMessageStillResumesAFinishedTurn() async throws {
        let sessionId = "transcript-resume-\(UUID().uuidString)"
        let store = SessionStore.shared
        let finished = try await makeFinishedSession(sessionId)

        let prompt = [message(id: "u3", role: .user, at: finished.lastActivity.addingTimeInterval(5))]
        await store.process(.fileUpdated(payload(sessionId: sessionId, messages: prompt)))

        let resumedSession = await store.session(for: sessionId)
        let afterPrompt = try XCTUnwrap(resumedSession)
        XCTAssertEqual(
            afterPrompt.phase,
            .processing,
            "A user message written after the turn ended is the user starting the next one"
        )

        await store.process(.sessionArchived(sessionId: sessionId))
    }
}
