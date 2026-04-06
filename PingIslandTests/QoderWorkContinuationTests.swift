import Foundation
import XCTest
@testable import Ping_Island

final class QoderWorkContinuationTests: XCTestCase {
    func testQoderWorkResolvedInterventionWaitsForClientContinuation() async {
        let sessionId = "qoderwork-cont-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderWorkQuestionEvent(sessionId: sessionId)))
        await store.process(.interventionResolved(sessionId: sessionId, nextPhase: .processing))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertFalse(session?.intervention?.supportsInlineResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderWorkContinuationClearsAfterNewMessageArrives() async {
        let sessionId = "qoderwork-msg-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderWorkQuestionEvent(sessionId: sessionId)))
        await store.process(.interventionResolved(sessionId: sessionId, nextPhase: .processing))
        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-next",
                        role: .assistant,
                        timestamp: Date(),
                        content: [.text("继续处理后续任务")]
                    )
                ],
                isIncremental: true,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertEqual(session?.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderWorkContinuationClearsAfterFiveMinuteTimeout() async {
        let sessionId = "qoderwork-timeout-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderWorkQuestionEvent(sessionId: sessionId)))
        await store.process(.interventionResolved(sessionId: sessionId, nextPhase: .processing))

        let answeredAt = await store.session(for: sessionId)?.intervention?.externalContinuationAnsweredAt
        XCTAssertNotNil(answeredAt)

        await store.process(
            .pruneTimedOutExternalContinuations(
                now: answeredAt?.addingTimeInterval(301) ?? Date().addingTimeInterval(301)
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertEqual(session?.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func makeQoderWorkQuestionEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "topic",
                        "header": "主题",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_\(sessionId)",
            notificationType: nil,
            message: nil
        )
    }
}
