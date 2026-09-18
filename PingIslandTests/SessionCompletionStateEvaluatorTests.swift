import Foundation
import XCTest
@testable import Ping_Island

final class SessionCompletionStateEvaluatorTests: XCTestCase {
    func testCodexCompletionKeyUsesStableTurnIndependentOfTranscript() throws {
        var session = SessionState(
            sessionId: "codex-completion-key",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "codex-completion-key"),
            phase: .idle,
            chatItems: [
                ChatHistoryItem(
                    id: "assistant-1",
                    type: .assistant("Done"),
                    timestamp: Date(timeIntervalSince1970: 10)
                )
            ],
            latestTurnId: "turn-1",
            lastActivity: Date(timeIntervalSince1970: 10)
        )

        let first = try XCTUnwrap(SessionCompletionKey.make(for: session))
        session.lastActivity = Date(timeIntervalSince1970: 999)
        let replay = try XCTUnwrap(SessionCompletionKey.make(for: session))

        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.sessionId, "codex-completion-key")
        XCTAssertEqual(first.turnId, "turn-1")
        session.chatItems.append(ChatHistoryItem(
            id: "assistant-2",
            type: .assistant("Late transcript detail"),
            timestamp: Date(timeIntervalSince1970: 20)
        ))
        XCTAssertEqual(first, SessionCompletionKey.make(for: session))
        session.completionSequence += 1
        XCTAssertEqual(first, SessionCompletionKey.make(for: session))
        session.latestTurnId = "turn-2"
        XCTAssertNotEqual(first, SessionCompletionKey.make(for: session))
    }

    @MainActor
    func testCompletionNotificationRegistryUsesSharedCompletionKeyLogic() {
        let registry = SessionCompletionNotificationRegistry.shared
        var session = SessionState(
            sessionId: "codex-notification-key",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "codex-notification-key"),
            phase: .idle,
            chatItems: [
                ChatHistoryItem(
                    id: "assistant-1",
                    type: .assistant("Done"),
                    timestamp: Date(timeIntervalSince1970: 10)
                )
            ],
            latestTurnId: "turn-1",
            lastActivity: Date(timeIntervalSince1970: 10)
        )

        XCTAssertFalse(registry.isConsumed(session: session))
        registry.markConsumed(session: session)
        session.lastActivity = Date(timeIntervalSince1970: 999)
        XCTAssertTrue(registry.isConsumed(session: session))

        session.latestTurnId = "turn-2"
        session.chatItems = [
            ChatHistoryItem(
                id: "assistant-2",
                type: .assistant("Done again"),
                timestamp: Date(timeIntervalSince1970: 1_000)
            )
        ]
        XCTAssertFalse(registry.isConsumed(session: session))
    }

    func testAssistantlessCompletionKeyUsesStableCompletionSequenceInsteadOfActivity() throws {
        var session = SessionState(
            sessionId: "assistantless-completion",
            cwd: "/tmp/project",
            provider: .kimi,
            clientInfo: SessionClientInfo.default(for: .kimi),
            phase: .waitingForInput,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            completionSequence: 7,
            lastActivity: Date(timeIntervalSince1970: 10)
        )

        let first = try XCTUnwrap(SessionCompletionKey.make(for: session))
        session.lastActivity = Date(timeIntervalSince1970: 999)
        let replay = try XCTUnwrap(SessionCompletionKey.make(for: session))

        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.turnId, "completion-7")

        session.completionSequence = 8
        XCTAssertNotEqual(first, SessionCompletionKey.make(for: session))
    }

    func testCompletedAssistantReplyRejectsToolOnlyTail() {
        let session = SessionState(
            sessionId: "tool-tail",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "1", type: .assistant("我先去执行工具。"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(
                    id: "2",
                    type: .toolCall(
                        ToolCallItem(
                            name: "Read",
                            input: ["path": "/tmp/project/file.swift"],
                            status: .success,
                            result: "done",
                            structuredResult: nil,
                            subagentTools: []
                        )
                    ),
                    timestamp: Date(timeIntervalSince1970: 2)
                )
            ],
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "我先去执行工具。",
                lastMessageRole: "assistant",
                lastToolName: "Read",
                firstUserMessage: "看看这个文件",
                lastUserMessageDate: nil
            )
        )

        XCTAssertFalse(SessionCompletionStateEvaluator.hasCompletedAssistantReply(for: session))
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    func testCompletedReadySessionAcceptsWaitingForInputAssistantReply() {
        let session = SessionState(
            sessionId: "assistant-tail",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "1", type: .user("修一下完成提示"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(id: "2", type: .assistant("已经修好了。"), timestamp: Date(timeIntervalSince1970: 2))
            ],
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "已经修好了。",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "修一下完成提示",
                lastUserMessageDate: nil
            )
        )

        XCTAssertTrue(SessionCompletionStateEvaluator.hasCompletedAssistantReply(for: session))
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    func testCompletedReadySessionFallsBackToAssistantConversationStateWithoutHistoryItems() {
        let session = SessionState(
            sessionId: "assistant-fallback",
            cwd: "/tmp/project",
            previewText: "最终答复",
            phase: .waitingForInput,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "最终答复",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "给我最终结果",
                lastUserMessageDate: nil
            )
        )

        XCTAssertTrue(SessionCompletionStateEvaluator.hasCompletedAssistantReply(for: session))
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    func testStopWithoutFinalTranscriptStillQueuesOneCompletion() throws {
        let now = Date()
        var session = SessionState(
            sessionId: "hook-only-stop",
            cwd: "/tmp/project",
            provider: .claude,
            phase: .waitingForInput,
            completionSequence: 4,
            lastActivity: now,
            createdAt: now.addingTimeInterval(-100)
        )
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: .waitingForInput,
            isEnabled: true,
            now: now
        ))
        let originalKey = try XCTUnwrap(SessionCompletionKey.make(for: session))
        session.chatItems = [ChatHistoryItem(
            id: "late-assistant",
            type: .assistant("Done"),
            timestamp: now.addingTimeInterval(1)
        )]
        XCTAssertEqual(SessionCompletionKey.make(for: session), originalKey)
    }

    func testCodexIdleAssistantReplyIsCompletedReadySession() {
        let session = SessionState(
            sessionId: "codex-idle-final",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "codex-idle-final"),
            phase: .idle,
            chatItems: [
                ChatHistoryItem(id: "1", type: .user("修一下声音"), timestamp: Date(timeIntervalSince1970: 1)),
                ChatHistoryItem(id: "2", type: .assistant("已经修好了。"), timestamp: Date(timeIntervalSince1970: 2))
            ]
        )

        XCTAssertTrue(SessionCompletionStateEvaluator.hasCompletedAssistantReply(for: session))
        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    func testNonCodexIdleAssistantReplyIsNotCompletedReadySession() {
        let session = SessionState(
            sessionId: "claude-idle-final",
            cwd: "/tmp/project",
            provider: .claude,
            phase: .idle,
            chatItems: [
                ChatHistoryItem(id: "1", type: .assistant("Done"), timestamp: Date(timeIntervalSince1970: 1))
            ]
        )

        XCTAssertTrue(SessionCompletionStateEvaluator.hasCompletedAssistantReply(for: session))
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    func testCompletedReadySessionRejectsQuestionInterventionEvenWithAssistantReply() {
        let session = SessionState(
            sessionId: "question-intervention",
            cwd: "/tmp/project",
            intervention: SessionIntervention(
                id: "question-1",
                kind: .question,
                title: "需要补充信息",
                message: "请选择环境",
                options: [],
                questions: [],
                supportsSessionScope: false,
                metadata: [:]
            ),
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "1", type: .assistant("还差一个问题需要你回答。"), timestamp: Date(timeIntervalSince1970: 1))
            ],
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "还差一个问题需要你回答。",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "继续",
                lastUserMessageDate: nil
            )
        )

        XCTAssertTrue(SessionCompletionStateEvaluator.hasCompletedAssistantReply(for: session))
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    func testEndedNotificationAfterWaitingForInputSupportsBothQoderCLIs() {
        let qoderCLI = SessionState(
            sessionId: "qoder-cli",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli"
            ),
            phase: .ended
        )
        let claude = SessionState(
            sessionId: "claude",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            phase: .ended
        )
        let qoderCNCLI = SessionState(
            sessionId: "qoder-cn-cli",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cn-cli",
                name: "Qoder CN CLI",
                origin: "cli"
            ),
            phase: .ended
        )

        XCTAssertTrue(SessionCompletionStateEvaluator.allowsEndedNotificationAfterWaitingForInput(qoderCLI))
        XCTAssertTrue(SessionCompletionStateEvaluator.allowsEndedNotificationAfterWaitingForInput(qoderCNCLI))
        XCTAssertFalse(SessionCompletionStateEvaluator.allowsEndedNotificationAfterWaitingForInput(claude))
    }

    func testCompletionNotificationPolicyIgnoresOldUntrackedEndedSessions() {
        let now = Date()
        let session = SessionState(
            sessionId: "old-ended",
            cwd: "/tmp/project",
            phase: .ended,
            lastActivity: now,
            createdAt: now.addingTimeInterval(-2 * 60 * 60)
        )

        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueEndedNotification(
                for: session,
                previousPhase: nil,
                isEnabled: true,
                now: now
            )
        )
    }

    func testCompletionNotificationPolicyAllowsRecentUntrackedCompletedSessions() {
        let now = Date()
        let session = SessionState(
            sessionId: "recent-completed",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "assistant", type: .assistant("Done"), timestamp: now)
            ],
            createdAt: now.addingTimeInterval(-5)
        )

        XCTAssertTrue(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: nil,
                isEnabled: true,
                now: now
            )
        )
    }

    func testCompletionNotificationPolicyRejectsFakeNewUntrackedCompletedSessionWithOldActivity() {
        let now = Date()
        let session = SessionState(
            sessionId: "fake-new-completed",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "fake-new-completed"),
            phase: .idle,
            chatItems: [
                ChatHistoryItem(id: "assistant", type: .assistant("Done earlier"), timestamp: now.addingTimeInterval(-3_600))
            ],
            lastActivity: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-5)
        )

        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: nil,
                isEnabled: true,
                now: now
            )
        )
    }

    func testCodexCompletionNotificationPolicyRequiresActiveToIdleEdge() {
        let now = Date()
        let session = makeCodexCompletedSession(now: now)
        let approval = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: now.addingTimeInterval(-5)
        )

        XCTAssertTrue(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: .processing,
                isEnabled: true,
                now: now
            )
        )
        XCTAssertTrue(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: .waitingForInput,
                isEnabled: true,
                now: now
            )
        )
        XCTAssertTrue(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: .waitingForApproval(approval),
                isEnabled: true,
                now: now
            )
        )
        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: .idle,
                isEnabled: true,
                now: now
            )
        )
        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: nil,
                isEnabled: true,
                now: now
            )
        )
    }

    func testRemoteCodexSnapshotDoesNotCompleteFromAssistantHistory() {
        var session = makeCodexCompletedSession(now: Date())
        session.ingress = .remoteBridge
        session.conversationInfo = ConversationInfo(
            summary: nil, lastMessage: "Done", lastMessageRole: "assistant",
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        )

        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(session))
        XCTAssertNil(SessionCompletionKey.make(for: session))
    }

    func testRemoteCodexEmptyStopDoesNotPreviewAnEarlierReply() {
        for role in [nil, "user"] as [String?] {
            var session = makeCodexCompletedSession(now: Date())
            session.clientInfo = .codexCLI()
            session.ingress = .remoteBridge
            session.previewText = "Previous result"
            session.hasRemoteCodexTurnCompletion = true
            session.conversationInfo = ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: role,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            )

            XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
            XCTAssertNil(SessionCompletionPreviewBuilder.latestAssistantText(
                for: session, notificationKind: .completed
            ))
        }
    }

    func testRemoteCodexCompletionDoesNotWaitForReplyOrRequeueAfterEnrichment() {
        let now = Date()
        var session = makeCodexCompletedSession(now: now)
        session.ingress = .remoteBridge
        session.hasRemoteCodexTurnCompletion = true
        session.chatItems = [ChatHistoryItem(id: "prompt", type: .user("Do it"), timestamp: now)]
        session.conversationInfo = ConversationInfo(
            summary: nil, lastMessage: "Do it", lastMessageRole: "user",
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        )

        XCTAssertTrue(SessionCompletionStateEvaluator.isCompletedReadySession(session))
        XCTAssertNil(SessionCompletionPreviewBuilder.latestAssistantText(for: session))
        let completionKey = SessionCompletionKey.make(for: session)
        XCTAssertNotNil(completionKey)
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session, previousPhase: .processing, isEnabled: true, now: now
        ))
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session, previousPhase: .idle, isEnabled: true, now: now
        ))
        for previousPhase in [nil, .compacting, .ended] as [SessionPhase?] {
            XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session, previousPhase: previousPhase, isEnabled: true, now: now
            ))
        }
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session, previousPhase: .processing, isEnabled: false, now: now
        ))

        session.chatItems.append(ChatHistoryItem(id: "reply", type: .assistant("Done"), timestamp: now))
        session.conversationInfo = ConversationInfo(
            summary: nil, lastMessage: "Done", lastMessageRole: "assistant",
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        )
        XCTAssertEqual(SessionCompletionKey.make(for: session), completionKey)
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session, previousPhase: .idle, previousCompletionKey: completionKey,
            isEnabled: true, now: now
        ))

        session.completionSequence += 1
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session, previousPhase: .idle, previousCompletionKey: completionKey,
            isEnabled: true, now: now
        ))

        session.lastActivity = now.addingTimeInterval(-120)
        XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session, previousPhase: .processing, isEnabled: true, now: now
        ))
    }

    func testCodexWaitingForInputDoesNotQueueCompletionNotification() {
        let now = Date()
        let session = makeCodexCompletedSession(phase: .waitingForInput, now: now)

        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: .processing,
                isEnabled: true,
                now: now
            )
        )
    }

    func testCompletionNotificationPolicyAllowsTrackedEndedTransition() {
        let session = SessionState(
            sessionId: "tracked-ended",
            cwd: "/tmp/project",
            phase: .ended,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(
            SessionCompletionNotificationPolicy.shouldQueueEndedNotification(
                for: session,
                previousPhase: .processing,
                isEnabled: true
            )
        )
    }

    func testCompletionNotificationPolicyRejectsTrackedStaleCompletedTransition() {
        let now = Date()
        let session = SessionState(
            sessionId: "tracked-stale-completed",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "tracked-stale-completed"),
            phase: .idle,
            chatItems: [
                ChatHistoryItem(
                    id: "assistant",
                    type: .assistant("Done earlier"),
                    timestamp: now.addingTimeInterval(-3_600)
                )
            ],
            lastActivity: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-3_600)
        )

        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: session,
                previousPhase: .processing,
                isEnabled: true,
                now: now
            )
        )
    }

    func testCompletionNotificationPolicyRejectsTrackedStaleEndedTransition() {
        let now = Date()
        let session = SessionState(
            sessionId: "tracked-stale-ended",
            cwd: "/tmp/project",
            phase: .ended,
            lastActivity: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-3_600)
        )

        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueEndedNotification(
                for: session,
                previousPhase: .processing,
                isEnabled: true,
                now: now
            )
        )
    }

    func testCompletionNotificationPolicyRejectsTrackedStaleCompactedTransition() {
        let now = Date()
        let session = SessionState(
            sessionId: "tracked-stale-compacted",
            cwd: "/tmp/project",
            phase: .idle,
            lastActivity: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-3_600)
        )

        XCTAssertFalse(
            SessionCompletionNotificationPolicy.shouldQueueCompactedNotification(
                for: session,
                previousPhase: .compacting,
                isEnabled: true,
                now: now
            )
        )
    }

    @MainActor
    func testNotificationQueuePreservesConcurrentCompletionsAndTurnSnapshots() async throws {
        let registry = SessionCompletionNotificationRegistry()
        let firstSession = SessionState(
            sessionId: "codex-completed",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "codex-completed"),
            phase: .idle,
            latestTurnId: "turn-1"
        )
        let secondSession = SessionState(
            sessionId: "claude-completed",
            cwd: "/tmp/project",
            provider: .claude,
            phase: .waitingForInput,
            completionSequence: 2
        )
        let first = SessionCompletionNotification(session: firstSession, kind: .completed)
        let second = SessionCompletionNotification(session: secondSession, kind: .completed)
        registry.enqueue(first)
        registry.enqueue(second)
        registry.enqueue(first)

        XCTAssertEqual(registry.pendingNotifications.count, 2)
        XCTAssertEqual(try XCTUnwrap(registry.dequeueNext()).identity, first.identity)
        XCTAssertEqual(try XCTUnwrap(registry.dequeueNext()).identity, second.identity)
        XCTAssertNil(registry.dequeueNext())
        registry.enqueue(first)
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
    }

    private func makeCodexCompletedSession(
        phase: SessionPhase = .idle,
        now: Date
    ) -> SessionState {
        SessionState(
            sessionId: "codex-completed-\(UUID().uuidString)",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "codex-completed"),
            phase: phase,
            chatItems: [
                ChatHistoryItem(
                    id: "user",
                    type: .user("Do it"),
                    timestamp: now.addingTimeInterval(-10)
                ),
                ChatHistoryItem(id: "assistant", type: .assistant("Done"), timestamp: now)
            ],
            lastActivity: now,
            createdAt: now.addingTimeInterval(-20)
        )
    }
}
