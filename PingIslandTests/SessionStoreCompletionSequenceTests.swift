import XCTest
@testable import Ping_Island

final class SessionStoreCompletionSequenceTests: XCTestCase {
    @MainActor
    func testInterruptedCodexIdleDoesNotCompleteAndNextTurnCanComplete() async throws {
        let id = "codex-interrupted-completion-\(UUID().uuidString)"
        let store = SessionStore.shared
        var sounds = SessionSoundEdgeTracker()
        let now = Date()
        func snapshot(phase: SessionPhase, turn: String, interrupted: Bool, offset: Double) -> CodexThreadSnapshot {
            CodexThreadSnapshot(
                threadId: id, name: "Interrupted turn", preview: nil, cwd: "/tmp/\(id)",
                clientInfo: .codexApp(threadId: id), intervention: nil,
                createdAt: now, updatedAt: now.addingTimeInterval(offset), phase: phase,
                historyItems: phase == .idle && !interrupted ? [ChatHistoryItem(
                    id: "reply-\(turn)", type: .assistant("Done"), timestamp: now
                )] : [],
                conversationInfo: ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil,
                    lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil),
                latestTurnId: turn, latestResponseText: nil, latestResponsePhase: nil,
                latestUserText: nil, isTurnInterrupted: interrupted
            )
        }
        await store.syncCodexThreadSnapshot(snapshot(phase: .processing, turn: "turn-1", interrupted: false, offset: 0))
        let processing = await store.session(for: id)
        sounds.prime(with: [try XCTUnwrap(processing)])
        for offset in [1.0, 2.0] {
            await store.syncCodexThreadSnapshot(snapshot(phase: .idle, turn: "turn-1", interrupted: true, offset: offset))
            let current = await store.session(for: id)
            let interrupted = try XCTUnwrap(current)
            XCTAssertEqual(interrupted.phase, .idle)
            XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(interrupted))
            XCTAssertNil(SessionCompletionKey.make(for: interrupted))
            XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: interrupted, previousPhase: .processing, isEnabled: true
            ))
            XCTAssertNotEqual(sounds.edge(for: [interrupted])?.event, .taskCompleted)
        }
        await store.syncCodexThreadSnapshot(snapshot(phase: .idle, turn: "older-turn", interrupted: false, offset: 0.5))
        let olderTurn = await store.session(for: id)
        XCTAssertTrue(try XCTUnwrap(olderTurn).isCodexTurnInterrupted)
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(try XCTUnwrap(olderTurn)))
        await store.syncCodexThreadSnapshot(snapshot(phase: .processing, turn: "turn-1", interrupted: false, offset: 0.5))
        let staleActive = await store.session(for: id)
        XCTAssertTrue(try XCTUnwrap(staleActive).isCodexTurnInterrupted)
        await store.syncCodexThreadSnapshot(snapshot(phase: .idle, turn: "turn-1", interrupted: false, offset: 2))
        let replayedIdle = await store.session(for: id)
        XCTAssertEqual(replayedIdle?.phase, .idle)
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(try XCTUnwrap(replayedIdle)))
        let enriched = await store.commitTranscriptUpdate(try XCTUnwrap(processing), basedOn: try XCTUnwrap(processing))
        XCTAssertTrue(try XCTUnwrap(enriched).isCodexTurnInterrupted)
        // A shallow idle refresh does not know whether this turn was aborted.
        await store.upsertCodexSession(
            sessionId: id, name: nil, preview: nil, cwd: "/tmp/\(id)", phase: .idle,
            intervention: nil, activityAt: now.addingTimeInterval(2.1)
        )
        await store.syncCodexThreadSnapshot(snapshot(phase: .idle, turn: "turn-1", interrupted: false, offset: 2.2))
        let refreshed = await store.session(for: id)
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(try XCTUnwrap(refreshed)))
        await store.syncCodexThreadSnapshot(snapshot(phase: .processing, turn: "turn-2", interrupted: false, offset: 3))
        let resumed = await store.session(for: id)
        _ = sounds.edge(for: [try XCTUnwrap(resumed)])
        await store.syncCodexThreadSnapshot(snapshot(phase: .idle, turn: "turn-2", interrupted: false, offset: 4))
        let finished = await store.session(for: id)
        let completed = try XCTUnwrap(finished)
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(completed))
        XCTAssertEqual(sounds.edge(for: [completed])?.event, .taskCompleted)
        // Restoring an aborted snapshot needs no preceding live phase, and a
        // newer completed turn must clear it even if its running phase was missed.
        await store.process(.sessionArchived(sessionId: id))
        await store.syncCodexThreadSnapshot(snapshot(phase: .idle, turn: "turn-2", interrupted: true, offset: 5))
        let restored = await store.session(for: id)
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(try XCTUnwrap(restored)))
        await store.syncCodexThreadSnapshot(snapshot(phase: .idle, turn: "turn-3", interrupted: false, offset: 6))
        let nextCompleted = await store.session(for: id)
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(try XCTUnwrap(nextCompleted)))
        await store.process(.sessionArchived(sessionId: id))
    }

    func testDetectedInterruptRejectsActivityGeneratedBeforeInterruption() async throws {
        let id = "detected-interrupt-replay-\(UUID().uuidString)"
        let store = SessionStore.shared
        let now = Date()
        await store.upsertCodexSession(
            sessionId: id, name: nil, preview: nil, cwd: "/tmp/\(id)",
            phase: .processing, intervention: nil, activityAt: now.addingTimeInterval(-60)
        )
        await store.process(.interruptDetected(sessionId: id))
        await store.upsertCodexSession(
            sessionId: id, name: nil, preview: nil, cwd: "/tmp/\(id)",
            phase: .processing, intervention: nil, activityAt: now.addingTimeInterval(-30)
        )
        let interrupted = await store.session(for: id)
        XCTAssertTrue(try XCTUnwrap(interrupted).isCodexTurnInterrupted)
        await store.upsertCodexSession(
            sessionId: id, name: nil, preview: nil, cwd: "/tmp/\(id)",
            phase: .processing, intervention: nil, activityAt: Date().addingTimeInterval(1)
        )
        let resumed = await store.session(for: id)
        XCTAssertFalse(try XCTUnwrap(resumed).isCodexTurnInterrupted)
        await store.process(.sessionArchived(sessionId: id))
    }

    @MainActor
    func testMultipleCompactionsInOneTurnEachNotifyWithoutSurfaceDuplicates() async throws {
        let id = "compaction-notification-\(UUID().uuidString)"
        let store = SessionStore.shared
        let registry = SessionCompletionNotificationRegistry()
        await store.process(.hookReceived(makeKimiEvent(sessionId: id, event: "UserPromptSubmit", status: "processing")))
        var previousIdentity: SessionCompletionNotification.Identity?
        for cycle in 1...2 {
            let before = await store.session(for: id)
            let original = try XCTUnwrap(before)
            await store.process(.hookReceived(makeKimiEvent(sessionId: id, event: "PreCompact", status: "compacting")))
            await store.process(.hookReceived(makeKimiEvent(sessionId: id, event: "PreCompact", status: "compacting")))
            await store.process(.hookReceived(makeKimiEvent(sessionId: id, event: "PostToolUse", status: "processing")))
            let after = await store.session(for: id)
            let compacted = try XCTUnwrap(after)
            XCTAssertEqual(compacted.compactionSequence, UInt64(cycle))
            XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompactedNotification(
                for: compacted, previousPhase: .compacting, isEnabled: true
            ))
            let notification = SessionCompletionNotification(session: compacted, kind: .compacted)
            XCTAssertNotEqual(notification.identity, previousIdentity)
            registry.enqueue(notification)
            registry.enqueue(SessionCompletionNotification(session: compacted, kind: .compacted))
            XCTAssertEqual(registry.pendingNotifications.count, 1)
            XCTAssertNotNil(registry.dequeueNext())
            XCTAssertNil(registry.dequeueNext())
            // A transcript captured before the whole compacting cycle cannot
            // rewind its notification identity even when the phase matches again.
            let enriched = await store.commitTranscriptUpdate(original, basedOn: original)
            XCTAssertEqual(
                enriched.map { SessionCompletionNotification(session: $0, kind: .compacted).identity },
                notification.identity
            )
            XCTAssertEqual(compacted.completionSequence, original.completionSequence)
            previousIdentity = notification.identity
        }
        await store.process(.sessionArchived(sessionId: id))
    }

    func testCodexCompactionCyclesPreserveTheirCounterAcrossSnapshotRefreshes() async throws {
        let id = "codex-compaction-cycle-\(UUID().uuidString)"
        let store = SessionStore.shared
        let now = Date()
        for (index, phase) in [SessionPhase.processing, .compacting, .compacting, .processing].enumerated() {
            await store.syncCodexThreadSnapshot(CodexThreadSnapshot(
                threadId: id, name: "Compaction", preview: nil, cwd: "/tmp/\(id)",
                clientInfo: .codexApp(threadId: id), intervention: nil,
                createdAt: now, updatedAt: now.addingTimeInterval(Double(index)), phase: phase,
                historyItems: [],
                conversationInfo: ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil,
                    lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil),
                latestTurnId: "turn-1", latestResponseText: nil, latestResponsePhase: nil, latestUserText: nil
            ))
        }
        let first = await store.session(for: id)
        XCTAssertEqual(first?.compactionSequence, 1)
        for phase in [SessionPhase.compacting, .compacting, .processing] {
            await store.upsertCodexSession(
                sessionId: id, name: nil, preview: nil, cwd: "/tmp/\(id)", phase: phase,
                intervention: nil, activityAt: now.addingTimeInterval(4)
            )
        }
        let second = await store.session(for: id)
        XCTAssertEqual(second?.compactionSequence, 2)
        XCTAssertEqual(second?.completionSequence, first?.completionSequence)
        XCTAssertEqual(second?.latestTurnId, "turn-1")
        await store.process(.sessionArchived(sessionId: id))
    }

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
