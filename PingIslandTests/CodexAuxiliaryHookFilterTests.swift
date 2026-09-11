import Foundation
import XCTest
@testable import Ping_Island

final class CodexAuxiliaryHookFilterTests: XCTestCase {
    func testAuxiliarySourcesAreExactAndDoNotHideUserCreatedSuggestionTasks() {
        for source in [
            "thread_title", "thread_description", "thread_summary", "thread_title_reconsideration",
            "ambient_suggestions", "ambient_suggestion_safety"
        ] {
            XCTAssertTrue(CodexAuxiliaryHookFilter.isCodexAuxiliaryThread(
                cwd: "/tmp/project", title: "project", preview: #"{"title":"Project title"}"#,
                metadata: ["thread_source": source]
            ), source)
        }

        for source in ["user", "ambient_suggestion_task", "subagent", "title", "cli", "vscode"] {
            for response in [#"{"title":"Project title"}"#, #"{"suggestions":[]}"#, #"{"exclude":[]}"#] {
                XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexAuxiliaryThread(
                    cwd: "/tmp/project", title: "project", preview: response,
                    metadata: ["thread_source": source]
                ), "\(source): \(response)")
            }
        }
    }

    func testTitlePromptUsesSharedFilterAndDoesNotMatchQuotedExamples() {
        let prompt = "You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt. The title you generate will be shown in the UI to represent the prompt."
        XCTAssertTrue(CodexAuxiliaryHookFilter.isCodexAuxiliaryThread(
            cwd: "/tmp/project", title: "Project title", preview: #"{"title":"Project title"}"#,
            metadata: ["prompt": prompt]
        ))
        XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexTitleGenerationPrompt("Please review this prompt: " + prompt))
        XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexAuxiliaryThread(
            cwd: "/tmp/project", title: "Project title", preview: "Please review this prompt: " + prompt
        ))
        XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexAuxiliaryThread(
            cwd: "/tmp/project", title: "Project title", preview: prompt,
            metadata: ["prompt": "Show me how Codex generates titles"]
        ))
    }

    func testTitleCheckpointAndVoiceTitlePromptsAreRecognized() {
        for prompt in [
            "You are in a fork of an existing Codex thread at a possible durable title checkpoint. The current UI title is: Project task. Decide whether the thread's main durable purpose has changed so substantially that the current title is now misleading. Do not respond to the user or do any other work; only fill the structured fields.",
            "You are in a fork of a voice chat. Generate a concise UI title (up to 36 characters) for the conversation in the thread context above. Fill the structured title field with plain text. Do not respond to the user or do any other work; only fill the title and description fields."
        ] {
            XCTAssertTrue(CodexAuxiliaryHookFilter.isCodexTitleGenerationPrompt(prompt))
            XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexTitleGenerationPrompt("Explain this prompt: " + prompt))
        }
    }

    func testSuggestionPromptIsRecognizedWithoutMatchingNormalRequestsOrQuotedExamples() {
        let prompt = "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /tmp/project"
        XCTAssertTrue(CodexAuxiliaryHookFilter.isCodexSuggestionGenerationPrompt(prompt))
        XCTAssertTrue(CodexAuxiliaryHookFilter.isCodexSuggestionGenerationPrompt(
            "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this Projectless task"
        ))
        XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexSuggestionGenerationPrompt("Suggest improvements to this project"))
        XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexSuggestionGenerationPrompt("Please review this prompt: " + prompt))
        XCTAssertFalse(CodexAuxiliaryHookFilter.isCodexSuggestionGenerationPrompt(#"{"suggestions":[]}"#))

        var filter = CodexAuxiliaryHookFilter()
        XCTAssertTrue(filter.shouldIgnore(provider: .codex, sessionId: "helper", eventType: "UserPromptSubmit",
            title: "project", preview: prompt, cwd: "/tmp/project", metadata: [:]))
        XCTAssertTrue(filter.shouldIgnore(provider: .codex, sessionId: "helper", eventType: "PostToolUse",
            title: nil, preview: "Read project files", metadata: [:]))
        XCTAssertTrue(filter.shouldIgnore(provider: .codex, sessionId: "helper", eventType: "Stop",
            title: nil, preview: #"{"suggestions":[]}"#, metadata: [:]))
        XCTAssertFalse(filter.shouldIgnore(provider: .claude, sessionId: "user", eventType: "UserPromptSubmit",
            title: nil, preview: prompt, metadata: [:]))
    }

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
