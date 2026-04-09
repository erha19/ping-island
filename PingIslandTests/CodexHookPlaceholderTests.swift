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

    private func makeCodexEvent(
        sessionId: String,
        event: String,
        status: String,
        message: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/ping-island-codex-placeholder",
            event: event,
            status: status,
            provider: .codex,
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex_cli",
                name: "Codex CLI",
                bundleIdentifier: "com.openai.codex"
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
