import Foundation
import XCTest
@testable import NotchCode

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

    func testIgnoresCurrentCodexTitleGenerationPromptWording() {
        var filter = CodexAuxiliaryHookFilter()
        let prompt = """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt. The tasks typically have to do with coding-related tasks, for example requests for bug fixes or questions about a codebase. The title you generate will be shown in the UI to represent the prompt. Generate a concise UI title (up to 36 characters) for this task.
        """

        XCTAssertTrue(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-current-title-helper",
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

    func testIgnoresCodexMemoryMaintenanceWorkspace() {
        var filter = CodexAuxiliaryHookFilter()

        XCTAssertTrue(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-memory-maintenance",
                eventType: "SessionStart",
                title: "memories",
                preview: nil,
                cwd: "/tmp/ping-island-home/.codex/memories",
                metadata: [:]
            )
        )

        XCTAssertTrue(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-memory-maintenance",
                eventType: "Stop",
                title: "Stop",
                preview: "Created MEMORY.md",
                metadata: [:]
            )
        )
    }

    func testIgnoresCodexMemoryMaintenanceSummaryWhenTitleMatches() {
        var filter = CodexAuxiliaryHookFilter()

        XCTAssertTrue(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-memory-summary",
                eventType: "Stop",
                title: "memories",
                preview: "Created MEMORY.md and memory_summary.md from the new inputs.",
                metadata: [:]
            )
        )
    }

    func testDoesNotIgnoreNormalMemoriesProject() {
        var filter = CodexAuxiliaryHookFilter()

        XCTAssertFalse(
            filter.shouldIgnore(
                provider: .codex,
                sessionId: "codex-user-memories-project",
                eventType: "UserPromptSubmit",
                title: "memories",
                preview: "Add search to my notes app",
                cwd: "/tmp/ping-island-work/memories",
                metadata: ["prompt": "Add search to my notes app"]
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
