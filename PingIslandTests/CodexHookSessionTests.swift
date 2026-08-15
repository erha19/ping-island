import Foundation
import XCTest
@testable import Ping_Island

final class CodexHookSessionTests: XCTestCase {
    func testCodexAppSessionStartWithoutMessageStaysIdleUntilPrompt() async {
        let sessionId = "codex-session-start-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeCodexSessionStartEvent(sessionId: sessionId)))

        let startedSession = await store.session(for: sessionId)
        XCTAssertNotNil(startedSession)
        XCTAssertEqual(startedSession?.provider, .codex)
        XCTAssertEqual(startedSession?.phase, .idle)
        XCTAssertEqual(startedSession?.clientInfo.kind, .codexApp)
        XCTAssertFalse(startedSession?.needsAttention ?? true)

        await store.process(.hookReceived(makeCodexUserPromptSubmitEvent(sessionId: sessionId)))

        let promptedSession = await store.session(for: sessionId)
        XCTAssertEqual(promptedSession?.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexIdlePromptDoesNotDowngradeActiveSession() async {
        let sessionId = "codex-idle-prompt-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeCodexSessionStartEvent(sessionId: sessionId)))
        await store.process(.hookReceived(makeCodexUserPromptSubmitEvent(sessionId: sessionId)))
        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "Notification",
                status: "waiting_for_input",
                provider: .codex,
                clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: "idle_prompt",
                message: "Idle heartbeat"
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexTitleGenerationPromptStillGetsIgnored() async {
        let sessionId = "codex-title-generation-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeCodexTitleGenerationPromptEvent(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testCodexTitleGenerationSessionDoesNotRebindToExistingThread() async {
        let existingSessionId = "codex-existing-\(UUID().uuidString)"
        let titleSessionId = "codex-title-helper-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.upsertCodexSession(
            sessionId: existingSessionId,
            name: "Existing task",
            preview: "Real user work",
            cwd: "/tmp/project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: "/tmp/project/rollout-existing.jsonl"
            )
        )

        await store.process(.hookReceived(makeCodexSessionStartEvent(sessionId: titleSessionId)))
        await store.process(.hookReceived(makeCodexCurrentTitleGenerationPromptEvent(sessionId: titleSessionId)))
        await store.process(.hookReceived(makeCodexStopEvent(sessionId: titleSessionId)))

        let existingSession = await store.session(for: existingSessionId)
        let titleSession = await store.session(for: titleSessionId)
        XCTAssertEqual(existingSession?.phase, .idle)
        XCTAssertEqual(existingSession?.previewText, "Real user work")
        XCTAssertNil(titleSession)

        await store.process(.sessionArchived(sessionId: existingSessionId))
    }

    private func makeCodexSessionStartEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "SessionStart",
            status: "waiting_for_input",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    private func makeCodexUserPromptSubmitEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "Investigate the session popup."
        )
    }

    private func makeCodexTitleGenerationPromptEvent(sessionId: String) -> HookEvent {
        let prompt = """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
        Generate a concise UI title (18-36 characters) for this task.
        Return only the title. No quotes or trailing punctuation.
        """

        return HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: prompt
        )
    }

    private func makeCodexCurrentTitleGenerationPromptEvent(sessionId: String) -> HookEvent {
        let prompt = """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt. The tasks typically have to do with coding-related tasks, for example requests for bug fixes or questions about a codebase. The title you generate will be shown in the UI to represent the prompt. Generate a concise UI title (up to 36 characters) for this task.
        """

        return HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: prompt
        )
    }

    private func makeCodexStopEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "Stop",
            status: "completed",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "{\"title\":\"Respond to greeting\"}"
        )
    }
}
