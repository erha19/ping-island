import XCTest
@testable import Ping_Island

final class CodexHookPlaceholderTests: XCTestCase {
    func testWeakCodexSessionStartSeedsPlaceholderSession() async {
        let sessionId = "codex-start-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeCodexEvent(
                sessionId: sessionId,
                event: "SessionStart",
                status: "waiting_for_input"
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.provider, .codex)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.ingress, .hookBridge)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testWeakCodexUserPromptSubmitSeedsPlaceholderSession() async {
        let sessionId = "codex-prompt-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeCodexEvent(
                sessionId: sessionId,
                event: "UserPromptSubmit",
                status: "processing"
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.provider, .codex)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.ingress, .hookBridge)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexTitleGenerationPromptIsStillIgnored() async {
        let sessionId = "codex-title-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeCodexEvent(
                sessionId: sessionId,
                event: "UserPromptSubmit",
                status: "processing",
                message: """
                You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
                Generate a concise UI title (18-36 characters) for this task.
                Return only the title. No quotes or trailing punctuation.
                """
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testSuggestionHookRemovesPlaceholderAndIgnoresToolAndCompletionEvents() async {
        let sessionId = "suggestion-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeCodexEvent(sessionId: sessionId, event: "SessionStart", status: "waiting_for_input")))
        await store.process(.hookReceived(makeCodexEvent(sessionId: sessionId, event: "UserPromptSubmit", status: "processing",
            message: "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project")))
        await store.process(.hookReceived(makeCodexEvent(sessionId: sessionId, event: "PostToolUse", status: "processing", message: "Read files")))
        await store.process(.hookReceived(makeCodexEvent(sessionId: sessionId, event: "Stop", status: "waiting_for_input", message: #"{"suggestions":[]}"#)))
        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testTitleHelperSourceIsIgnoredWithPersistedRolloutAndNoOpeningPrompt() async {
        let sessionId = "title-source-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeCodexEvent(
            sessionId: sessionId, event: "SessionStart", status: "processing",
            threadSource: "thread_title", sessionFilePath: "/tmp/project/title-helper.jsonl"
        )))
        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testNormalJSONResponsesAndRootWorkspaceAreNotAuxiliaryEvidence() async {
        let store = SessionStore.shared
        for message in [#"{"title":"Project title"}"#, #"{"suggestions":[]}"#, #"{"exclude":[]}"#] {
            let sessionId = "json-task-\(UUID().uuidString)"
            await store.process(.hookReceived(makeCodexEvent(
                sessionId: sessionId, event: "UserPromptSubmit", status: "processing",
                message: message, cwd: "/", threadSource: "ambient_suggestion_task"
            )))
            let session = await store.session(for: sessionId)
            XCTAssertNotNil(session)
            XCTAssertFalse(session?.shouldHideFromPrimaryUI ?? true)
            await store.process(.sessionArchived(sessionId: sessionId))
        }
    }

    func testCodexMemoryMaintenanceHookIsIgnored() async {
        let sessionId = "codex-memory-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            makeCodexEvent(
                sessionId: sessionId,
                event: "SessionStart",
                status: "waiting_for_input",
                cwd: "/tmp/ping-island-home/.codex/memories"
            )
        ))

        await store.process(.hookReceived(
            makeCodexEvent(
                sessionId: sessionId,
                event: "Stop",
                status: "waiting_for_input",
                message: "Created MEMORY.md and memory_summary.md from the new inputs.",
                cwd: "/tmp/ping-island-home/.codex/memories"
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testCodexMemoryMaintenanceAppServerUpsertIsIgnored() async {
        let sessionId = "codex-memory-upsert-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "memories",
            preview: "Created MEMORY.md and memory_summary.md from the new inputs.",
            cwd: "/tmp/ping-island-home/.codex/memories",
            phase: .waitingForInput,
            intervention: nil,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId)
        )

        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testCodexMemoryMaintenanceSnapshotIsIgnored() async {
        let sessionId = "codex-memory-snapshot-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.syncCodexThreadSnapshot(CodexThreadSnapshot(
            threadId: sessionId,
            name: "memories",
            preview: "Created MEMORY.md and memory_summary.md from the new inputs.",
            cwd: "/tmp/ping-island-home/.codex/memories",
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            intervention: nil,
            createdAt: Date(),
            updatedAt: Date(),
            phase: .waitingForInput,
            historyItems: [],
            conversationInfo: ConversationInfo(
                summary: "memories",
                lastMessage: "Created MEMORY.md and memory_summary.md from the new inputs.",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "update memory",
                lastUserMessageDate: Date()
            ),
            latestTurnId: nil,
            latestResponseText: "Created MEMORY.md and memory_summary.md from the new inputs.",
            latestResponsePhase: "final",
            latestUserText: "update memory"
        ))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testSuggestionSnapshotRemovesPreviouslyIngestedSession() async {
        let sessionId = "codex-memory-snapshot-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.upsertCodexSession(sessionId: sessionId, name: "project", preview: "Working", cwd: "/tmp/project", phase: .processing, intervention: nil)
        await store.syncCodexThreadSnapshot(CodexThreadSnapshot(
            threadId: sessionId,
            name: "project",
            preview: "No suggestions available.",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            intervention: nil,
            createdAt: Date(),
            updatedAt: Date(),
            phase: .waitingForInput,
            historyItems: [],
            conversationInfo: ConversationInfo(
                summary: "project",
                lastMessage: "No suggestions available.",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project",
                lastUserMessageDate: Date()
            ),
            latestTurnId: nil,
            latestResponseText: "No suggestions available.",
            latestResponsePhase: "final",
            latestUserText: "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project"
        ))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testTitleSnapshotRemovesPreviouslyIngestedSessionByOpeningPrompt() async {
        let sessionId = "codex-title-snapshot-\(UUID().uuidString)"
        let store = SessionStore.shared
        let prompt = "You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt. The title you generate will be shown in the UI to represent the prompt."
        await store.upsertCodexSession(
            sessionId: sessionId, name: "Project title", preview: "Working", cwd: "/tmp/project",
            phase: .processing, intervention: nil
        )
        await store.syncCodexThreadSnapshot(CodexThreadSnapshot(
            threadId: sessionId, name: "Project title", preview: #"{"title":"Project title"}"#,
            cwd: "/tmp/project", clientInfo: .codexApp(threadId: sessionId), intervention: nil,
            createdAt: Date(), updatedAt: Date(), phase: .waitingForInput, historyItems: [],
            conversationInfo: ConversationInfo(
                summary: "Project title", lastMessage: #"{"title":"Project title"}"#,
                lastMessageRole: "assistant", lastToolName: nil,
                firstUserMessage: prompt, lastUserMessageDate: Date()
            ),
            latestTurnId: nil, latestResponseText: #"{"title":"Project title"}"#,
            latestResponsePhase: "final", latestUserText: prompt
        ))
        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    private func makeCodexEvent(
        sessionId: String,
        event: String,
        status: String,
        message: String? = nil,
        cwd: String = "/tmp/ping-island-codex-placeholder",
        threadSource: String? = nil,
        sessionFilePath: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: event,
            status: status,
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex_cli",
                name: "Codex CLI",
                bundleIdentifier: "com.openai.codex",
                threadSource: threadSource,
                sessionFilePath: sessionFilePath
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: message
        )
    }
}
