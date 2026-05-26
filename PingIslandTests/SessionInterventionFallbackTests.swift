import XCTest
@testable import Ping_Island

final class SessionInterventionFallbackTests: XCTestCase {
    func testResolvedQuestionsFallsBackToToolInputJSON() {
        let intervention = SessionIntervention(
            id: "question-fallback",
            kind: .question,
            title: "Claude needs input",
            message: "你希望我在这个项目中如何协助你？",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "toolInputJSON": """
                {
                  "questions": [
                    {
                      "id": "assist_mode",
                      "header": "协助方式",
                      "question": "你希望我在这个项目中如何协助你？",
                      "options": [
                        { "label": "修复bug", "description": "诊断和修复代码中的问题" },
                        { "label": "开发新功能", "description": "实现新的功能或模块" }
                      ],
                      "multiSelect": false
                    }
                  ]
                }
                """
            ]
        )

        XCTAssertEqual(intervention.resolvedQuestions.count, 1)
        XCTAssertEqual(intervention.resolvedQuestions.first?.prompt, "你希望我在这个项目中如何协助你？")
        XCTAssertEqual(intervention.resolvedQuestions.first?.options.map(\.title), ["修复bug", "开发新功能"])
        XCTAssertEqual(intervention.summaryText, "你希望我在这个项目中如何协助你？")
    }

    func testConversationParserPreservesStructuredAskUserQuestionInput() async throws {
        let sessionId = "parser-question-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-parser-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(sessionId).jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let transcript = """
        {"parentUuid":"root","isSidechain":false,"message":{"role":"assistant","content":[{"name":"AskUserQuestion","input":{"questions":[{"question":"你今天想先处理什么？","header":"今日目标","options":[{"label":"修复bug"},{"label":"添加新功能"}],"multiSelect":false}]},"id":"toolu_parser_question","type":"tool_use"}]},"type":"assistant","uuid":"assistant-tool","timestamp":"2026-04-08T17:23:01.254Z","cwd":"/tmp/project","sessionId":"\(sessionId)"}
        """
        try transcript.write(to: fileURL, atomically: true, encoding: .utf8)

        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: "/tmp/project",
            explicitFilePath: fileURL.path
        )

        guard let firstMessage = messages.first,
              case let .toolUse(tool) = try XCTUnwrap(firstMessage.content.first) else {
            XCTFail("Expected a tool use block")
            return
        }

        XCTAssertEqual(tool.name, "AskUserQuestion")
        XCTAssertTrue(tool.input["questions"]?.contains("你今天想先处理什么？") == true)
        XCTAssertTrue(tool.input["questions"]?.contains("修复bug") == true)
    }

    func testClaudeTranscriptToolUseFallbackCreatesQuestionIntervention() async {
        let sessionId = "claude-transcript-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(
                    kind: .claudeCode,
                    profileID: "claude_code",
                    name: "Claude Code",
                    bundleIdentifier: "com.anthropic.claudecode"
                ),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "使用工具问我一个问题"
            )
        ))

        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-tool",
                        role: .assistant,
                        timestamp: Date(),
                        content: [
                            .toolUse(ToolUseBlock(
                                id: "toolu_transcript_question",
                                name: "AskUserQuestion",
                                input: [
                                    "questions": """
                                    [{"question":"你今天想先处理什么？","header":"今日目标","options":[{"label":"修复bug"},{"label":"添加新功能"}],"multiSelect":false}]
                                    """
                                ]
                            ))
                        ]
                    )
                ],
                isIncremental: true,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.prompt, "你今天想先处理什么？")
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.options.map(\.title), ["修复bug", "添加新功能"])

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCompletedClaudeQuestionToolClearsTranscriptFallbackIntervention() async {
        let sessionId = "claude-transcript-completed-\(UUID().uuidString)"
        let toolUseId = "toolu_transcript_question_completed"
        let store = SessionStore.shared

        await store.process(.hookReceived(
            HookEvent(
                sessionId: sessionId,
                cwd: "/tmp/project",
                event: "UserPromptSubmit",
                status: "processing",
                provider: .claude,
                clientInfo: SessionClientInfo(
                    kind: .claudeCode,
                    profileID: "claude_code",
                    name: "Claude Code",
                    bundleIdentifier: "com.anthropic.claudecode"
                ),
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: "使用工具问我一个问题"
            )
        ))

        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [
                    ChatMessage(
                        id: "assistant-tool",
                        role: .assistant,
                        timestamp: Date(),
                        content: [
                            .toolUse(ToolUseBlock(
                                id: toolUseId,
                                name: "AskUserQuestion",
                                input: [
                                    "questions": """
                                    [{"question":"你今天想先处理什么？","header":"今日目标","options":[{"label":"修复bug"},{"label":"添加新功能"}],"multiSelect":false}]
                                    """
                                ]
                            ))
                        ]
                    )
                ],
                isIncremental: true,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        ))

        var session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)

        await store.process(.fileUpdated(
            FileUpdatePayload(
                sessionId: sessionId,
                cwd: "/tmp/project",
                messages: [],
                isIncremental: true,
                completedToolIds: [toolUseId],
                toolResults: [
                    toolUseId: ConversationParser.ToolResult(
                        content: "Answered in transcript",
                        stdout: nil,
                        stderr: nil,
                        isError: false
                    )
                ],
                structuredResults: [:]
            )
        ))

        session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertFalse(session?.needsQuestionResponse ?? true)
        XCTAssertEqual(session?.phase, .processing)

        guard let toolItem = session?.chatItems.first(where: { $0.id == toolUseId }),
              case .toolCall(let tool) = toolItem.type else {
            XCTFail("Expected AskUserQuestion tool item")
            await store.process(.sessionArchived(sessionId: sessionId))
            return
        }
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.result, "Answered in transcript")

        await store.process(.sessionArchived(sessionId: sessionId))
    }
}
