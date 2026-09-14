import Foundation
import XCTest
@testable import Ping_Island

final class RemoteCodexStopCompletionTests: XCTestCase {
    func testStopPromotesFinalReplyAndCompletesTurn() async {
        let sessionId = "codex-remote-stop-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the remote task.", sessionId: sessionId, store: store)
        await processStop("Remote work is complete.", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(session?.lastMessageRole, "assistant")
        XCTAssertEqual(session?.lastMessage, "Remote work is complete.")
        XCTAssertEqual(assistantMessages(in: session), ["Remote work is complete."])
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testRepeatedStopDoesNotDuplicateAssistantTail() async {
        let sessionId = "codex-remote-stop-repeat-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the remote task.", sessionId: sessionId, store: store)
        await processStop("Remote work is complete.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)
        await processStop("Remote work is complete.", sessionId: sessionId, store: store)
        await processStop(nil, sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(assistantMessages(in: session), ["Remote work is complete."])
        XCTAssertEqual(session.flatMap(SessionCompletionKey.make(for:)), firstKey)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testLiteralStopReplyCountsAsCompletion() async {
        let sessionId = "codex-remote-stop-literal-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Reply with one word.", sessionId: sessionId, store: store)
        await processStop("Stop", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(session?.lastMessageRole, "assistant")
        XCTAssertEqual(assistantMessages(in: session), ["Stop"])
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testStopWithoutFinalReplyDoesNotReuseEarlierCompletion() async {
        let store = SessionStore.shared
        let prompts: [String?] = ["Complete the second task.", nil, "", " \n\t"]

        for prompt in prompts {
            let sessionId = "codex-remote-stop-empty-\(UUID().uuidString)"
            await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
            await processStop("Done.", sessionId: sessionId, store: store)
            await processPrompt(prompt, sessionId: sessionId, store: store)
            await processStop(nil, sessionId: sessionId, store: store)

            let session = await store.session(for: sessionId)
            XCTAssertEqual(session?.phase, .idle)
            XCTAssertEqual(session?.lastMessageRole, "user")
            XCTAssertEqual(assistantMessages(in: session), ["Done."])
            XCTAssertFalse(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? true)
            XCTAssertNil(session.flatMap(SessionCompletionKey.make(for:)))

            await store.process(.sessionArchived(sessionId: sessionId))
        }
    }

    func testSameReplyCompletesNewTurnAfterMissingPromptBody() async {
        let sessionId = "codex-remote-stop-missing-prompt-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)

        await processPrompt(nil, sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done.", "Done."])
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)
        let completionKey = session.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(completionKey)
        XCTAssertNotEqual(completionKey, firstKey)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    @MainActor
    func testEmptyStopAfterMissingPromptAndToolIDDoesNotReuseEarlierCompletion() async {
        let sessionId = "codex-remote-stop-missing-boundary-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)

        for event in ["PreToolUse", "PostToolUse"] {
            await store.process(.hookReceived(makeEvent(
                sessionId: sessionId,
                event: event,
                status: event == "PreToolUse" ? "running_tool" : "processing",
                message: nil,
                tool: "shell"
            )))
        }
        await processStop(nil, sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done."])
        XCTAssertFalse(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? true)
        XCTAssertNil(session.flatMap(SessionCompletionKey.make(for:)))
        XCTAssertFalse(session.map {
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: $0, previousPhase: .processing, isEnabled: true
            )
        } ?? true)

        // A delayed final reply still completes this turn, even if the text repeats.
        await processStop("Done.", sessionId: sessionId, store: store)
        let completedSession = await store.session(for: sessionId)
        XCTAssertEqual(assistantMessages(in: completedSession), ["Done.", "Done."])
        let completionKey = completedSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(completionKey)
        XCTAssertNotEqual(completionKey, firstKey)
        XCTAssertTrue(completedSession.map {
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: $0,
                previousPhase: session?.phase,
                wasCompletedReady: session.map(SessionCompletionStateEvaluator.isCompletedReadySession),
                isEnabled: true
            )
        } ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSameReplyCompletesNewTurnAfterMissingPromptEvent() async {
        let sessionId = "codex-remote-stop-missing-event-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)

        for event in ["PreToolUse", "PostToolUse"] {
            await store.process(.hookReceived(makeEvent(
                sessionId: sessionId,
                event: event,
                status: event == "PreToolUse" ? "running_tool" : "processing",
                message: nil,
                tool: "shell",
                toolUseId: "remote-tool-\(sessionId)"
            )))
        }
        await processStop("Done.", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done.", "Done."])
        let completionKey = session.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(completionKey)
        XCTAssertNotEqual(completionKey, firstKey)

        await processStop("Done.", sessionId: sessionId, store: store)
        let replayedSession = await store.session(for: sessionId)
        XCTAssertEqual(assistantMessages(in: replayedSession), ["Done.", "Done."])
        XCTAssertEqual(replayedSession.flatMap(SessionCompletionKey.make(for:)), completionKey)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testConversationPreservesFormattingWithoutInjectedReminders() async {
        let sessionId = "codex-remote-stop-formatting-\(UUID().uuidString)"
        let store = SessionStore.shared
        let prompt = "Review this code:\n\n```python\nif ready:\n    run()\n```"
        let reply = "## Result\n\n```python\nif ready:\n    run_safely()\n```\n\n- Updated the call."

        await processPrompt("<system-reminder>Client context</system-reminder>\n\(prompt)", sessionId: sessionId, store: store)
        await processStop("\(reply)\n<system-reminder>Client context</system-reminder>", sessionId: sessionId, store: store)
        await processStop(reply, sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        let userMessages = session?.chatItems.compactMap { item -> String? in
            guard case .user(let message) = item.type else { return nil }
            return message
        }
        XCTAssertEqual(userMessages, [prompt])
        XCTAssertEqual(assistantMessages(in: session), [reply])
        XCTAssertEqual(session?.conversationInfo.firstUserMessage, prompt)
        XCTAssertEqual(session?.conversationInfo.lastMessage, reply)
        XCTAssertEqual(session?.previewText, reply)
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func processPrompt(_ message: String?, sessionId: String, store: SessionStore) async {
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            message: message
        )))
    }

    private func processStop(_ message: String?, sessionId: String, store: SessionStore) async {
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input",
            message: message
        )))
    }

    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        message: String?,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/remote-project-\(sessionId)",
            event: event,
            status: status,
            provider: .codex,
            clientInfo: .codexCLI(),
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: message,
            ingress: .remoteBridge
        )
    }

    private func assistantMessages(in session: SessionState?) -> [String] {
        session?.chatItems.compactMap { item in
            guard case .assistant(let message) = item.type else { return nil }
            return message
        } ?? []
    }
}
