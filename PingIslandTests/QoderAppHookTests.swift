import XCTest
@testable import Ping_Island

final class QoderAppHookTests: XCTestCase {
    private let clients = [
        (profile: "qoder-app", name: "Qoder", bundle: "com.qoder.app"),
        (profile: "qoder-cn-app", name: "Qoder CN", bundle: "com.aliyun.lingma.ide")
    ]

    func testAppQuestionKeepsAnswerTransportAndExternalNotice() throws {
        for client in clients {
            for hook in ["PreToolUse", "PermissionRequest"] {
                let event = try makeEvent(client: client, hook: hook)
                XCTAssertEqual(event.clientInfo.profileID, client.profile)
                XCTAssertEqual(event.clientInfo.badgeLabel(for: .claude), client.name)
                XCTAssertTrue(event.expectsResponse)
                XCTAssertFalse(event.shouldFilterBeforeApprovalHandling)
                XCTAssertTrue(event.isAskUserQuestionRequest)
                let intervention = try XCTUnwrap(event.intervention)
                XCTAssertEqual(intervention.kind, .question)
                XCTAssertFalse(intervention.supportsInlineResponse)
                XCTAssertEqual(intervention.id, "app-question")
                let answer = try XCTUnwrap(SessionMonitor.defaultQoderAutoAnswer(for: event))
                XCTAssertEqual(answer.toolUseId, "app-question")
                XCTAssertEqual(answer.answers, ["topic": ["First"]])
                let encoded = try XCTUnwrap(answer.updatedInput["answers"] as? [String: String])
                XCTAssertEqual(encoded["topic"], "First")
                XCTAssertEqual(encoded["Choose a topic"], "First")
                XCTAssertEqual(encoded["Topic"], "First")
            }
        }
    }

    func testAppPermissionRequestRemainsActionable() async throws {
        for client in clients {
            let event = try makeEvent(client: client, hook: "PermissionRequest", tool: "Bash")
            XCTAssertTrue(event.expectsResponse)
            XCTAssertFalse(event.shouldFilterBeforeApprovalHandling)
            XCTAssertFalse(event.shouldSuppressApprovalHandling)
            XCTAssertNil(SessionMonitor.defaultQoderAutoAnswer(for: event))
            await SessionStore.shared.process(.hookReceived(event))
            let stored = await SessionStore.shared.session(for: event.sessionId)
            let session = try XCTUnwrap(stored)
            XCTAssertTrue(session.needsApprovalResponse)
            var tracker = SessionManualAttentionTracker()
            XCTAssertEqual(tracker.consumeNewAttentionSession(from: [session])?.sessionId, event.sessionId)
            await SessionStore.shared.process(.sessionArchived(sessionId: event.sessionId))
        }
    }

    @MainActor
    func testAutoAnsweredAppQuestionStillTriggersAttentionAndOpenClientAction() async throws {
        let monitor = SessionMonitor(observeSharedState: false)
        for client in clients {
            let event = try makeEvent(client: client, hook: "PermissionRequest")
            await monitor.handleIncomingHookEvent(event)
            let stored = await SessionStore.shared.session(for: event.sessionId)
            let session = try XCTUnwrap(stored)
            XCTAssertEqual(session.phase, .waitingForInput)
            XCTAssertTrue(session.needsQuestionResponse)
            XCTAssertTrue(session.clientInfo.prefersAnsweredQuestionFollowupAction)
            XCTAssertEqual(session.interactionDisplayName, client.name)
            XCTAssertTrue(session.intervention?.awaitsExternalContinuation == true)
            XCTAssertEqual(session.intervention?.submittedAnswers, ["topic": ["First"]])
            var tracker = SessionManualAttentionTracker()
            XCTAssertEqual(tracker.consumeNewAttentionSession(from: [session])?.sessionId, event.sessionId)
            XCTAssertNil(tracker.consumeNewAttentionSession(from: [session]))
            await SessionStore.shared.process(.sessionArchived(sessionId: event.sessionId))
        }
    }

    func testAppFreeTextQuestionDoesNotInventDefaultAnswer() throws {
        for client in clients {
            let event = try makeEvent(client: client, hook: "PreToolUse", options: [])
            XCTAssertTrue(event.expectsResponse)
            XCTAssertEqual(event.intervention?.kind, .question)
            XCTAssertTrue(event.intervention?.supportsInlineResponse == true)
            XCTAssertNil(SessionMonitor.defaultQoderAutoAnswer(for: event))
        }
    }

    func testNotifyOnlyCNQuestionStillShowsExternalAttentionWithoutSendingAnswer() async throws {
        let event = try makeEvent(
            client: ("qoder-cn", "Qoder CN", "com.aliyun.lingma.ide"),
            hook: "PreToolUse", expectsResponse: false
        )
        XCTAssertFalse(event.expectsResponse)
        XCTAssertEqual(event.intervention?.kind, .question)
        XCTAssertFalse(event.intervention?.supportsInlineResponse ?? true)
        XCTAssertNil(SessionMonitor.defaultQoderAutoAnswer(for: event))
        await SessionStore.shared.process(.hookReceived(event))
        let stored = await SessionStore.shared.session(for: event.sessionId)
        let session = try XCTUnwrap(stored)
        XCTAssertTrue(session.needsQuestionResponse)
        XCTAssertEqual(session.interactionDisplayName, "Qoder CN")
        var tracker = SessionManualAttentionTracker()
        XCTAssertEqual(tracker.consumeNewAttentionSession(from: [session]), session)
        await SessionStore.shared.process(.sessionArchived(sessionId: event.sessionId))
    }

    func testPersistedCLIIdentityWithAppEvidenceIsRepaired() {
        var session = SessionState(sessionId: "qoder-app-cache", cwd: "/tmp/qoder-app-fixture")
        session.clientInfo = SessionClientInfo(
            kind: .qoder, profileID: "qoder-cli", name: "Qoder CLI",
            bundleIdentifier: "com.qoder.app", origin: "cli",
            processName: "/Applications/Qoder.app/Contents/MacOS/Qoder"
        )
        let key = SessionAssociationStore.cacheKey(provider: .claude, sessionId: session.sessionId)
        let repaired = SessionAssociationStore.normalizedAssociations([key: .init(session: session)])
        XCTAssertEqual(repaired[key]?.clientInfo.profileID, "qoder-app")
        XCTAssertEqual(repaired[key]?.clientInfo.name, "Qoder")
        XCTAssertEqual(repaired[key]?.clientInfo.origin, "desktop")
    }

    func testExplicitCLIProductBeatsInheritedAppBundleWithoutProcessPath() throws {
        for client in [("qoder-cli", "Qoder CLI", "com.qoder.app"),
                       ("qoder-cn-cli", "Qoder CN CLI", "com.aliyun.lingma.ide")] {
            let event = try makeEvent(
                client: client, hook: "PreToolUse", extraMetadata: ["qoder_product": "cli"]
            )
            XCTAssertTrue(event.clientInfo.isQoderCLIClient)
            XCTAssertFalse(event.clientInfo.isQoderDesktopAppClient)
            XCTAssertEqual(event.clientInfo.profileID, client.0)
            XCTAssertTrue(event.intervention?.supportsInlineResponse == true)
            XCTAssertNil(SessionMonitor.defaultQoderAutoAnswer(for: event))
        }
    }

    private func makeEvent(
        client: (profile: String, name: String, bundle: String),
        hook: String,
        tool: String = "AskUserQuestion",
        options: [String] = ["First", "Second"],
        expectsResponse: Bool = true,
        extraMetadata: [String: String] = [:]
    ) throws -> HookEvent {
        let input: [String: Any] = tool == "AskUserQuestion" ? ["questions": [[
            "id": "topic", "header": "Topic", "question": "Choose a topic",
            "options": options.map { ["label": $0] }
        ]]] : ["command": "pwd"]
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let metadata = [
            "client_kind": client.profile, "client_name": client.name,
            "client_bundle_id": client.bundle, "client_origin": "app",
            "tool_name": tool, "tool_use_id": "app-question", "tool_input_json": inputJSON
        ].merging(extraMetadata) { _, new in new }
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "provider": "claude", "eventType": hook,
            "sessionKey": "claude:app-test-\(UUID().uuidString)",
            "cwd": "/tmp/qoder-app-fixture",
            "status": ["kind": tool == "AskUserQuestion" ? "waitingForInput" : "waitingForApproval"],
            "expectsResponse": expectsResponse,
            "terminalContext": ["terminalBundleID": client.bundle],
            "metadata": metadata
        ]
        return try HookSocketServer.decodeHookEvent(from: JSONSerialization.data(withJSONObject: envelope))
    }
}
