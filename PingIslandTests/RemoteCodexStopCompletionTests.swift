import Foundation
import XCTest
@testable import Ping_Island

@MainActor
final class RemoteCodexStopCompletionTests: XCTestCase {
    private let store = SessionStore.shared

    func testEmptyStopAfterSnapshotDiscoveryCompletesOnceWithoutPrompt() async throws {
        for status in ["idle", "processing"] {
            let sessionId = makeSessionID()
            var sounds = SessionSoundEdgeTracker()
            sounds.prime(with: [])

            let discovered = try await processSnapshot(sessionId: sessionId, status: status)
            for snapshot in [discovered, try await processSnapshot(sessionId: sessionId, status: status)] {
                XCTAssertEqual(snapshot.phase, .idle)
                XCTAssertFalse(snapshot.shouldHideFromPrimaryUI)
                XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(snapshot))
                XCTAssertNil(SessionCompletionKey.make(for: snapshot))
                XCTAssertNotEqual(sounds.edge(for: [snapshot])?.event, .taskCompleted)
            }

            let stopped = try await processStop(nil, sessionId: sessionId)
            let key = try XCTUnwrap(SessionCompletionKey.make(for: stopped))
            XCTAssertEqual(sounds.edge(for: [stopped])?.event, .taskCompleted)
            XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: stopped, previousPhase: discovered.phase,
                previousCompletionKey: SessionCompletionKey.make(for: discovered), isEnabled: true
            ))

            for reply in [nil, "Done.", "Done."] as [String?] {
                let snapshot = try await processSnapshot(sessionId: sessionId)
                XCTAssertEqual(SessionCompletionKey.make(for: snapshot), key)
                XCTAssertNil(sounds.edge(for: [snapshot]))

                let refreshed = try await processStop(reply, sessionId: sessionId)
                XCTAssertEqual(SessionCompletionKey.make(for: refreshed), key)
                XCTAssertNil(sounds.edge(for: [refreshed]))
                XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                    for: refreshed, previousPhase: snapshot.phase, previousCompletionKey: key,
                    isEnabled: true
                ))
            }
        }
    }

    func testTranscriptEnrichmentPreservesStopAfterSnapshotDiscovery() async throws {
        let sessionId = makeSessionID()
        let original = try await processSnapshot(sessionId: sessionId)
        let stopped = try await processStop(nil, sessionId: sessionId)
        let key = try XCTUnwrap(SessionCompletionKey.make(for: stopped))
        let committed = await store.commitTranscriptUpdate(original, basedOn: original)
        XCTAssertEqual(committed.flatMap(SessionCompletionKey.make(for:)), key)
    }

    func testTranscriptEnrichmentDoesNotRestoreStopDuringNewTurn() async throws {
        let sessionId = makeSessionID()
        let original = try await processStop(nil, sessionId: sessionId)
        try await processPrompt(nil, sessionId: sessionId)
        let committed = await store.commitTranscriptUpdate(original, basedOn: original)
        XCTAssertEqual(committed?.phase, .processing)
        XCTAssertEqual(committed?.hasRemoteCodexTurnCompletion, false)
        XCTAssertNil(committed.flatMap(SessionCompletionKey.make(for:)))
    }

    func testFinalRepliesCompleteOnceWithoutDuplicatingAssistantTail() async throws {
        for reply in ["Remote work is complete.", "Stop"] {
            let sessionId = makeSessionID()
            try await processPrompt("Complete the remote task.", sessionId: sessionId)
            let completed = try await processStop(reply, sessionId: sessionId)
            XCTAssertEqual(completed.phase, .idle)
            XCTAssertEqual(completed.lastMessageRole, "assistant")
            XCTAssertEqual(completed.lastMessage, reply)
            XCTAssertEqual(assistantMessages(in: completed), [reply])
            XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(completed))
            let key = try XCTUnwrap(SessionCompletionKey.make(for: completed))

            try await processSnapshot(sessionId: sessionId)
            try await processStop(reply, sessionId: sessionId)
            let replayed = try await processStop(nil, sessionId: sessionId)
            XCTAssertEqual(assistantMessages(in: replayed), [reply])
            XCTAssertEqual(replayed.previewText, reply)
            XCTAssertEqual(SessionCompletionPreviewBuilder.latestUserText(for: replayed), "Complete the remote task.")
            XCTAssertEqual(SessionCompletionKey.make(for: replayed), key)
        }
    }

    func testStopWithoutFinalReplyCompletesNewTurnWithoutReusingEarlierReply() async throws {
        let prompts: [(message: String?, expectedPreview: String?)] = [
            ("Complete the second task.", "Complete the second task."),
            (nil, nil), ("", nil), (" \n\t", nil)
        ]

        for (prompt, expectedPreview) in prompts {
            let sessionId = makeSessionID()
            let firstKey = try await completeFirstTurn(sessionId: sessionId)
            let processing = try await processPrompt(prompt, sessionId: sessionId)
            XCTAssertNil(processing.previewText)
            XCTAssertEqual(processing.lastMessage, expectedPreview)

            let session = try await processStop(nil, sessionId: sessionId)
            XCTAssertEqual(session.phase, .idle)
            XCTAssertEqual(session.lastMessageRole, "user")
            XCTAssertNil(session.previewText)
            XCTAssertEqual(session.lastMessage, expectedPreview)
            XCTAssertEqual(assistantMessages(in: session), ["Done."])
            XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
            XCTAssertNil(SessionCompletionPreviewBuilder.latestAssistantText(for: session))
            let key = try XCTUnwrap(SessionCompletionKey.make(for: session))
            XCTAssertNotEqual(key, firstKey)
        }
    }

    func testMissingPromptDoesNotPairEarlierQuestionWithNewReply() async throws {
        for prompt in [nil, "", " \n\t"] as [String?] {
            let sessionId = makeSessionID()
            try await processPrompt("Question A", sessionId: sessionId)
            try await processStop("Reply A", sessionId: sessionId)
            try await processPrompt(prompt, sessionId: sessionId)
            let completed = try await processStop("Reply B", sessionId: sessionId)
            XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: completed))
            XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: completed), "Reply B")
            XCTAssertEqual(completed.conversationInfo.firstUserMessage, "Question A")
            XCTAssertEqual(assistantMessages(in: completed), ["Reply A", "Reply B"])

            try await processPrompt("Question C", sessionId: sessionId)
            let next = try await processStop("Reply C", sessionId: sessionId)
            XCTAssertEqual(SessionCompletionPreviewBuilder.latestUserText(for: next), "Question C")
            XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: next), "Reply C")
        }
    }

    func testSameReplyCompletesNewTurnAfterMissingPromptBody() async throws {
        let sessionId = makeSessionID()
        let firstKey = try await completeFirstTurn(sessionId: sessionId)
        try await processPrompt(nil, sessionId: sessionId)
        let session = try await processStop("Done.", sessionId: sessionId)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done.", "Done."])
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
        let key = try XCTUnwrap(SessionCompletionKey.make(for: session))
        XCTAssertNotEqual(key, firstKey)
    }

    func testEmptyStopAfterMissingPromptAndToolIDDoesNotReuseEarlierCompletion() async throws {
        let sessionId = makeSessionID()
        let firstKey = try await completeFirstTurn(sessionId: sessionId)
        let active = try await processToolActivity(sessionId: sessionId)
        XCTAssertFalse(active.hasRemoteCodexTurnCompletion)
        XCTAssertNil(active.previewText)
        XCTAssertNil(active.lastMessage)
        XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: active))

        let session = try await processStop(nil, sessionId: sessionId)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done."])
        XCTAssertNil(session.previewText)
        XCTAssertNil(session.lastMessage)
        XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: session))
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
        XCTAssertNil(SessionCompletionPreviewBuilder.latestAssistantText(for: session))
        let emptyStopKey = try XCTUnwrap(SessionCompletionKey.make(for: session))
        XCTAssertNotEqual(emptyStopKey, firstKey)
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session, previousPhase: .processing, isEnabled: true
        ))

        // A delayed final reply enriches the completed turn without changing its identity.
        let completed = try await processStop("Done.", sessionId: sessionId)
        XCTAssertEqual(assistantMessages(in: completed), ["Done.", "Done."])
        XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: completed))
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: completed), "Done.")
        XCTAssertEqual(SessionCompletionKey.make(for: completed), emptyStopKey)
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: completed, previousPhase: session.phase, previousCompletionKey: emptyStopKey,
            isEnabled: true
        ))
    }

    func testStopsNotifyOncePerTurnAndLateRepliesDoNotReplay() async throws {
        let sessionId = makeSessionID()
        let registry = SessionCompletionNotificationRegistry()
        var sounds = SessionSoundEdgeTracker()
        var previousKey: SessionCompletionKey?

        for turn in 1...5 {
            // Resume with a prompt, no prompt event, then a missing prompt body.
            if turn > 2 {
                let resumed = try await processHook(
                    "SessionStart", status: "waiting_for_input", message: nil, sessionId: sessionId
                )
                for session in [resumed, try await processSnapshot(sessionId: sessionId, status: "processing")] {
                    XCTAssertEqual(session.phase, .waitingForInput)
                    XCTAssertEqual(session.completionSequence, UInt64(turn - 2))
                    XCTAssertNotEqual(sounds.edge(for: [session])?.event, .taskCompleted)
                }
            }
            let processing: SessionState
            if turn == 4 {
                processing = try await processToolActivity(
                    sessionId: sessionId, toolUseId: "remote-tool-\(sessionId)"
                )
                XCTAssertNil(processing.previewText)
                XCTAssertNil(processing.lastMessage)
                XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: processing))
                XCTAssertNil(SessionCompletionPreviewBuilder.latestAssistantText(for: processing))
            } else {
                let prompt = turn == 5 ? nil : "Complete task \(turn)."
                processing = try await processPrompt(prompt, sessionId: sessionId)
            }
            XCTAssertEqual(processing.completionSequence, UInt64(turn - 1))
            XCTAssertFalse(processing.hasRemoteCodexTurnCompletion)
            if turn == 1 {
                sounds.prime(with: [processing])
            } else {
                _ = sounds.edge(for: [processing])
            }

            let stopped = try await processStop(turn == 3 || turn == 4 ? "Done." : nil, sessionId: sessionId)
            if turn == 4 {
                XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: stopped))
                XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: stopped), "Done.")
            }
            let key = try XCTUnwrap(SessionCompletionKey.make(for: stopped))
            XCTAssertNotEqual(key, previousKey)
            XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: stopped, previousPhase: processing.phase, isEnabled: true
            ))
            XCTAssertEqual(sounds.edge(for: [stopped])?.event, .taskCompleted)
            registry.enqueue(SessionCompletionNotification(session: stopped, kind: .completed))
            let notification = try XCTUnwrap(registry.dequeueNext())
            XCTAssertEqual(notification.identity, .completed(key))

            for reply in [nil, "Done.", "Late reply."] as [String?] {
                let snapshot = try await processSnapshot(sessionId: sessionId, status: "processing")
                XCTAssertEqual(SessionCompletionKey.make(for: snapshot), key)
                XCTAssertNil(sounds.edge(for: [snapshot]))
                let refreshed = try await processStop(reply, sessionId: sessionId)
                XCTAssertEqual(SessionCompletionKey.make(for: refreshed), key)
                XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                    for: refreshed, previousPhase: .idle, previousCompletionKey: key, isEnabled: true
                ))
                XCTAssertNil(sounds.edge(for: [refreshed]))
                registry.enqueue(SessionCompletionNotification(session: refreshed, kind: .completed))
                XCTAssertNil(registry.dequeueNext())
            }
            previousKey = key
        }

        let session = await store.session(for: sessionId)
        XCTAssertEqual(
            assistantMessages(in: try XCTUnwrap(session)),
            Array(repeating: ["Done.", "Late reply."], count: 5).flatMap { $0 }
        )
    }

    func testSameReplyCompletesNewTurnAfterMissingPromptEvent() async throws {
        let sessionId = makeSessionID()
        let firstKey = try await completeFirstTurn(sessionId: sessionId)
        let active = try await processToolActivity(
            sessionId: sessionId, message: "Current tool activity", toolUseId: "remote-tool-\(sessionId)"
        )
        XCTAssertNil(active.previewText)
        XCTAssertEqual(active.lastMessage, "Current tool activity")
        XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: active))

        let session = try await processStop("Done.", sessionId: sessionId)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done.", "Done."])
        XCTAssertNil(SessionCompletionPreviewBuilder.latestUserText(for: session))
        let key = try XCTUnwrap(SessionCompletionKey.make(for: session))
        XCTAssertNotEqual(key, firstKey)

        let replayed = try await processStop("Done.", sessionId: sessionId)
        XCTAssertEqual(assistantMessages(in: replayed), ["Done.", "Done."])
        XCTAssertEqual(SessionCompletionKey.make(for: replayed), key)
    }

    func testConversationPreservesFormattingWithoutInjectedReminders() async throws {
        let sessionId = makeSessionID()
        let prompt = "Review this code:\n\n```python\nif ready:\n    run()\n```"
        let reply = "## Result\n\n```python\nif ready:\n    run_safely()\n```\n\n- Updated the call."

        try await processPrompt("<system-reminder>Client context</system-reminder>\n\(prompt)", sessionId: sessionId)
        try await processStop("\(reply)\n<system-reminder>Client context</system-reminder>", sessionId: sessionId)
        let session = try await processStop(reply, sessionId: sessionId)
        let userMessages = session.chatItems.compactMap { item -> String? in
            guard case .user(let message) = item.type else { return nil }
            return message
        }
        XCTAssertEqual(userMessages, [prompt])
        XCTAssertEqual(assistantMessages(in: session), [reply])
        XCTAssertEqual(session.conversationInfo.firstUserMessage, prompt)
        XCTAssertEqual(session.conversationInfo.lastMessage, reply)
        XCTAssertEqual(session.previewText, reply)
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    private func makeSessionID() -> String {
        let sessionId = "codex-remote-stop-\(UUID().uuidString)"
        addTeardownBlock {
            await SessionStore.shared.process(.sessionArchived(sessionId: sessionId))
        }
        return sessionId
    }

    private func completeFirstTurn(sessionId: String) async throws -> SessionCompletionKey {
        try await processPrompt("Complete the first task.", sessionId: sessionId)
        let session = try await processStop("Done.", sessionId: sessionId)
        return try XCTUnwrap(SessionCompletionKey.make(for: session))
    }

    @discardableResult
    private func processPrompt(_ message: String?, sessionId: String) async throws -> SessionState {
        try await processHook("UserPromptSubmit", status: "processing", message: message, sessionId: sessionId)
    }

    private func processToolActivity(
        sessionId: String, message: String? = nil, toolUseId: String? = nil
    ) async throws -> SessionState {
        try await processHook(
            "PreToolUse", status: "running_tool", message: message,
            sessionId: sessionId, tool: "shell", toolUseId: toolUseId
        )
        return try await processHook(
            "PostToolUse", status: "processing", message: message,
            sessionId: sessionId, tool: "shell", toolUseId: toolUseId
        )
    }

    @discardableResult
    private func processSnapshot(sessionId: String, status: String = "idle") async throws -> SessionState {
        try await processHook(
            "RemoteCodexThreadUpdated", status: status, message: "Remote task snapshot", sessionId: sessionId
        )
    }

    @discardableResult
    private func processStop(_ message: String?, sessionId: String) async throws -> SessionState {
        try await processHook("Stop", status: "waiting_for_input", message: message, sessionId: sessionId)
    }

    @discardableResult
    private func processHook(
        _ event: String, status: String, message: String?, sessionId: String,
        tool: String? = nil, toolUseId: String? = nil
    ) async throws -> SessionState {
        await store.process(.hookReceived(HookEvent(
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
        )))
        let session = await store.session(for: sessionId)
        return try XCTUnwrap(session)
    }

    private func assistantMessages(in session: SessionState) -> [String] {
        session.chatItems.compactMap { item in
            guard case .assistant(let message) = item.type else { return nil }
            return message
        }
    }
}
