import Foundation
import XCTest
@testable import Ping_Island

final class QoderWorkContinuationTests: XCTestCase {
    func testQoderIDEResolvedInterventionWaitsForClientContinuationNotification() async {
        let sessionId = "qoderide-cont-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "qoder",
                name: "Qoder",
                bundleIdentifier: "com.qoder.ide"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertTrue(session?.needsQuestionResponse ?? false)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertTrue(session?.intervention?.supportsInlineResponse ?? false)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])
        XCTAssertEqual(session?.intervention?.externalContinuationStatusMessage, "Qoder 有问题需要介入处理，可通过上方按钮快速打开并继续操作")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderIDEContinuationClearsAfterNewMessageArrives() async {
        let sessionId = "qoderide-msg-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "qoder",
                name: "Qoder",
                bundleIdentifier: "com.qoder.ide"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )
        let answeredAt = await store.session(for: sessionId)?.intervention?.externalContinuationAnsweredAt ?? Date()
        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-next",
                        role: .assistant,
                        timestamp: answeredAt.addingTimeInterval(1),
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

    func testQoderWorkResolvedInterventionWaitsForClientContinuation() async {
        let sessionId = "qoderwork-cont-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertFalse(session?.intervention?.supportsInlineResponse ?? true)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])
        XCTAssertEqual(session?.intervention?.questions.first?.options.first?.title, "A 方案")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodeBuddyResolvedInterventionWaitsForClientContinuation() async {
        let sessionId = "codebuddy-cont-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "codebuddy",
                name: "CodeBuddy",
                bundleIdentifier: "com.tencent.codebuddy"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertTrue(session?.intervention?.supportsInlineResponse ?? false)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testWorkBuddyResolvedInterventionWaitsForClientContinuation() async {
        let sessionId = "workbuddy-cont-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertFalse(session?.intervention?.supportsInlineResponse ?? true)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderWorkContinuationClearsAfterNewMessageArrives() async {
        let sessionId = "qoderwork-msg-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )
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

    func testCodeBuddyContinuationClearsAfterNewMessageArrives() async {
        let sessionId = "codebuddy-msg-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "codebuddy",
                name: "CodeBuddy",
                bundleIdentifier: "com.tencent.codebuddy"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )
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

    func testWorkBuddyContinuationClearsAfterNewMessageArrives() async {
        let sessionId = "workbuddy-msg-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )
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

    func testQoderWorkContinuationDoesNotClearOnFullSyncOfExistingMessages() async {
        let sessionId = "qoderwork-fullsync-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        let answeredAt = await store.session(for: sessionId)?.intervention?.externalContinuationAnsweredAt ?? Date()

        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-existing",
                        role: .assistant,
                        timestamp: answeredAt.addingTimeInterval(-10),
                        content: [.text("这是提交前就存在的旧消息")]
                    )
                ],
                isIncremental: false,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])
        XCTAssertEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderWorkContinuationDoesNotClearOnPostToolUseHook() async {
        let sessionId = "qoderwork-posttool-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "PostToolUse",
                status: "processing",
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
                toolInput: nil,
                toolUseId: "call_\(sessionId)",
                notificationType: nil,
                message: nil
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodeBuddyContinuationDoesNotClearOnPostToolUseHook() async {
        let sessionId = "codebuddy-posttool-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "codebuddy",
                name: "CodeBuddy",
                bundleIdentifier: "com.tencent.codebuddy"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "PostToolUse",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(
                    kind: .claudeCode,
                    profileID: "codebuddy",
                    name: "CodeBuddy",
                    bundleIdentifier: "com.tencent.codebuddy"
                ),
                pid: nil,
                tty: nil,
                tool: "AskUserQuestion",
                toolInput: nil,
                toolUseId: "call_\(sessionId)",
                notificationType: nil,
                message: nil
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodeBuddyContinuationDoesNotClearOnStopEndedHook() async {
        let sessionId = "codebuddy-stop-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "codebuddy",
                name: "CodeBuddy",
                bundleIdentifier: "com.tencent.codebuddy"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Stop",
                status: "ended",
                provider: .claude,
                clientInfo: SessionClientInfo(
                    kind: .claudeCode,
                    profileID: "codebuddy",
                    name: "CodeBuddy",
                    bundleIdentifier: "com.tencent.codebuddy"
                ),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: nil
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testWorkBuddyContinuationDoesNotClearOnPostToolUseHook() async {
        let sessionId = "workbuddy-posttool-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "workbuddy",
                name: "WorkBuddy",
                bundleIdentifier: "com.workbuddy.workbuddy"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "PostToolUse",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(
                    kind: .claudeCode,
                    profileID: "workbuddy",
                    name: "WorkBuddy",
                    bundleIdentifier: "com.workbuddy.workbuddy"
                ),
                pid: nil,
                tty: nil,
                tool: "AskUserQuestion",
                toolInput: nil,
                toolUseId: "call_\(sessionId)",
                notificationType: nil,
                message: nil
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertTrue(session?.intervention?.awaitsExternalContinuation ?? false)
        XCTAssertEqual(session?.intervention?.submittedAnswers["topic"], ["A 方案"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderWorkContinuationClearsAfterFiveMinuteTimeout() async {
        let sessionId = "qoderwork-timeout-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeQuestionEvent(
                sessionId: sessionId,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            )
        ))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["topic": ["A 方案"]]
            )
        )

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

    private func makeQuestionEvent(
        sessionId: String,
        profileID: String,
        name: String,
        bundleIdentifier: String
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: profileID == "qoder" || profileID == "qoderwork" ? .qoder : .claudeCode,
                profileID: profileID,
                name: name,
                bundleIdentifier: bundleIdentifier
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
