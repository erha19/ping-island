import Foundation
import XCTest
@testable import Ping_Island

final class SessionCompletionStateEvaluatorTests: XCTestCase {
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
        XCTAssertFalse(SessionCompletionStateEvaluator.isCompletedReadySession(session))
    }

    func testCompletedReadySessionRequiresWaitingForInputAssistantReply() {
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

    func testCompletionNotificationPolicyDetectsActiveSessionBlocker() {
        let codex = SessionState(
            sessionId: "codex-completed",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "codex-completed"),
            phase: .idle,
            chatItems: [
                ChatHistoryItem(id: "assistant", type: .assistant("Done"), timestamp: Date())
            ]
        )
        let activeClaude = SessionState(
            sessionId: "claude-active",
            cwd: "/tmp/project",
            provider: .claude,
            phase: .processing
        )
        let waitingClaude = SessionState(
            sessionId: "claude-waiting",
            cwd: "/tmp/project",
            provider: .claude,
            phase: .waitingForInput
        )
        let completedWaitingClaude = SessionState(
            sessionId: "claude-completed",
            cwd: "/tmp/project",
            provider: .claude,
            phase: .waitingForInput,
            chatItems: [
                ChatHistoryItem(id: "assistant", type: .assistant("Done"), timestamp: Date())
            ]
        )
        let activeCodex = SessionState(
            sessionId: "codex-active",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "codex-active"),
            phase: .processing
        )

        XCTAssertTrue(
            SessionCompletionNotificationPolicy.hasBlockingActiveSession(
                for: codex,
                in: [codex, activeClaude]
            )
        )
        XCTAssertTrue(
            SessionCompletionNotificationPolicy.hasBlockingActiveSession(
                for: codex,
                in: [codex, waitingClaude]
            )
        )
        XCTAssertFalse(
            SessionCompletionNotificationPolicy.hasBlockingActiveSession(
                for: codex,
                in: [codex, completedWaitingClaude]
            )
        )
        XCTAssertTrue(
            SessionCompletionNotificationPolicy.hasBlockingActiveSession(
                for: codex,
                in: [codex, activeCodex]
            )
        )
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
