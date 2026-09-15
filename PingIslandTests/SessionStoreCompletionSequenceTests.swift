import XCTest
@testable import Ping_Island

final class SessionStoreCompletionSequenceTests: XCTestCase {
    @MainActor
    func testCodexSnapshotReplayDoesNotRepeatCompletionEffects() async throws {
        let id = "codex-completion-replay-\(UUID().uuidString)"
        let store = SessionStore.shared
        let registry = SessionCompletionNotificationRegistry()
        var sounds = SessionSoundEdgeTracker()
        var firstKey: SessionCompletionKey?
        var firstSequence: UInt64?
        let now = Date()
        for (index, phase) in [SessionPhase.processing, .idle, .processing, .idle, .processing, .idle].enumerated() {
            let turnID = index < 4 ? "turn-1" : "turn-2"
            await store.syncCodexThreadSnapshot(CodexThreadSnapshot(
                threadId: id, name: "Replay", preview: "Done", cwd: "/tmp/\(id)",
                clientInfo: .codexApp(threadId: id), intervention: nil,
                createdAt: now, updatedAt: now.addingTimeInterval(Double(index)), phase: phase,
                historyItems: phase == .idle ? [ChatHistoryItem(
                    id: "reply-\(turnID)", type: .assistant("Done"), timestamp: now
                )] : [],
                conversationInfo: ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil,
                    lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil),
                latestTurnId: turnID, latestResponseText: phase == .idle ? "Done" : nil,
                latestResponsePhase: nil, latestUserText: nil
            ))
            let current = await store.session(for: id)
            let session = try XCTUnwrap(current)
            let sound = sounds.edge(for: [session])
            guard phase == .idle else { continue }
            let key = try XCTUnwrap(SessionCompletionKey.make(for: session))
            registry.enqueue(SessionCompletionNotification(session: session, kind: .completed))
            if index == 3 {
                XCTAssertGreaterThan(session.completionSequence, try XCTUnwrap(firstSequence))
                XCTAssertEqual(key, firstKey)
                XCTAssertNil(registry.dequeueNext())
                XCTAssertNotEqual(sound?.event, .taskCompleted)
            } else {
                XCTAssertNotNil(registry.dequeueNext())
                XCTAssertEqual(sound?.event, .taskCompleted)
                if index == 1 {
                    firstKey = key
                    firstSequence = session.completionSequence
                } else {
                    XCTAssertNotEqual(key, firstKey)
                }
            }
        }
        await store.process(.sessionArchived(sessionId: id))
    }

    func testHookCompletionSequenceStaysStableForReplayAndAdvancesForNewTurn() async throws {
        let sessionId = "kimi-completion-sequence-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeKimiEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(.hookReceived(makeKimiEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input"
        )))

        let firstSession = await awaitSession(store, sessionId: sessionId)
        let firstCompletion = try XCTUnwrap(firstSession)
        let firstKey = try XCTUnwrap(SessionCompletionKey.make(for: firstCompletion))
        XCTAssertEqual(firstCompletion.completionSequence, 0)

        await store.process(.hookReceived(makeKimiEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input"
        )))

        let replayedSession = await awaitSession(store, sessionId: sessionId)
        let replayedCompletion = try XCTUnwrap(replayedSession)
        XCTAssertEqual(replayedCompletion.completionSequence, 0)
        XCTAssertEqual(SessionCompletionKey.make(for: replayedCompletion), firstKey)

        await store.process(.hookReceived(makeKimiEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(.hookReceived(makeKimiEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input"
        )))

        let secondSession = await awaitSession(store, sessionId: sessionId)
        let secondCompletion = try XCTUnwrap(secondSession)
        XCTAssertEqual(secondCompletion.completionSequence, 1)
        XCTAssertNotEqual(SessionCompletionKey.make(for: secondCompletion), firstKey)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func awaitSession(_ store: SessionStore, sessionId: String) async -> SessionState? {
        await store.session(for: sessionId)
    }

    private func makeKimiEvent(
        sessionId: String,
        event: String,
        status: String
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/ping-island-kimi",
            event: event,
            status: status,
            provider: .kimi,
            clientInfo: SessionClientInfo.default(for: .kimi),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }
}
