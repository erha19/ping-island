import Foundation
import XCTest
@testable import Ping_Island

final class CodexHookSessionTests: XCTestCase {
    func testCodexSessionStartWithoutMessageIsKept() async {
        let sessionId = "codex-session-start-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeCodexSessionStartEvent(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.provider, .codex)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.clientInfo.kind, .codexApp)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexTitleGenerationPromptStillGetsIgnored() async {
        let sessionId = "codex-title-generation-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeCodexTitleGenerationPromptEvent(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    private func makeCodexSessionStartEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "SessionStart",
            status: "starting",
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
}
