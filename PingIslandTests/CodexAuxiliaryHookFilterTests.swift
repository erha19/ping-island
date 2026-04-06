import Foundation
import XCTest
@testable import Ping_Island

final class CodexAuxiliaryHookFilterTests: XCTestCase {
    func testIgnoresCodexTitleGenerationPrompt() {
        var filter = CodexAuxiliaryHookFilter()
        let prompt = """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
        Generate a concise UI title (18-36 characters) for this task.
        Return only the title. No quotes or trailing punctuation.
        """

        XCTAssertTrue(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-title-helper",
                eventType: "UserPromptSubmit",
                title: "UserPromptSubmit",
                preview: prompt,
                metadata: ["prompt": prompt]
            )
        )
    }

    func testIgnoresFollowupEventsForPreviouslyIgnoredTitleGenerationSession() {
        var filter = CodexAuxiliaryHookFilter()
        let prompt = """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
        Generate a concise UI title (18-36 characters) for this task.
        Return only the title. No quotes or trailing punctuation.
        """

        XCTAssertTrue(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-title-helper",
                eventType: "UserPromptSubmit",
                title: "UserPromptSubmit",
                preview: prompt,
                metadata: ["prompt": prompt]
            )
        )

        XCTAssertTrue(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-title-helper",
                eventType: "Stop",
                title: "Stop",
                preview: nil,
                metadata: [:]
            )
        )
    }

    func testDoesNotIgnoreNormalCodexUserPrompt() {
        var filter = CodexAuxiliaryHookFilter()

        XCTAssertFalse(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-user-task",
                eventType: "UserPromptSubmit",
                title: "UserPromptSubmit",
                preview: "帮我分析一下 SessionLauncher 的行为",
                metadata: ["prompt": "帮我分析一下 SessionLauncher 的行为"]
            )
        )
    }
}
