import Foundation
import IslandShared
import Testing

@Test
func mapsApprovalEventFromClaudePayload() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "tool_name": "Bash",
      "reason": "Needs to run tests",
      "session_id": "abc123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "iterm-1", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.sessionKey == "claude:abc123")
}

@Test
func mapsQuestionEventOptions() throws {
    let payload = """
    {
      "questions": [{
        "id": "terminal_scope",
        "question": "Which terminal?",
        "options": [
          {"label": "iTerm2", "description": "Primary recommendation"},
          {"label": "Terminal", "description": "Fallback"}
        ]
      }]
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .codex,
        arguments: ["island-bridge", "--source", "codex"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.intervention?.kind == .question)
    #expect(envelope.intervention?.options.count == 2)
    #expect(envelope.status?.kind == .waitingForInput)
}

@Test
func claudePermissionPayloadUsesHookSpecificOutput() throws {
    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: BridgeResponse(requestID: UUID(), decision: .approve),
        eventType: "PermissionRequest",
        metadata: [:]
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
}

@Test
func codeBuddyPreToolUseMapsToApprovalIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "tool_name": "Edit",
      "tool_input": {"file_path": "/tmp/demo.swift"},
      "permission_mode": "default",
      "session_id": "codebuddy-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "codebuddy"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse)
}

@Test
func codeBuddyAnswerPayloadUsesModifiedInput() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "answers": .object([
                "terminal_scope": .string("iTerm2")
            ])
        ]
    )
    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PreToolUse",
        metadata: ["client_kind": "codebuddy"]
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    #expect(json["permissionDecision"] as? String == "allow")
    let modifiedInput = try #require(json["modifiedInput"] as? [String: Any])
    let answers = try #require(modifiedInput["answers"] as? [String: String])
    #expect(answers["terminal_scope"] == "iTerm2")
}

@Test
func codeBuddyQuestionPayloadMapsToQuestionIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "tool_name": "ask_user_question",
      "tool_input": {
        "questions": [
          {
            "id": "terminal_scope",
            "question": "您希望在哪个终端继续？",
            "options": [
              {"label": "CodeBuddy 终端", "description": "留在当前 IDE"},
              {"label": "iTerm2", "description": "切到外部终端"}
            ]
          }
        ]
      },
      "session_id": "codebuddy-question-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "codebuddy"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.intervention?.kind == .question)
    #expect(envelope.expectsResponse)
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.metadata["tool_input_json"]?.contains("\"questions\"") == true)
}

@Test
func codeBuddyFollowupQuestionStringPayloadMapsToQuestionIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "tool_name": "ask_followup_question",
      "tool_input": {
        "questions": "[{\\"id\\":\\"q1\\",\\"question\\":\\"你想让我帮你做什么？\\",\\"options\\":[\\"创建一个新项目\\",\\"修复代码中的Bug\\",\\"添加新功能\\"],\\"multiSelect\\":false}]",
        "title": "我能帮你做什么？"
      },
      "session_id": "codebuddy-followup-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "codebuddy"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.intervention?.kind == .question)
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse)
}

@Test
func previewFallsBackToStructuredToolInput() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "tool_name": "Bash",
      "tool_input": {"command": "npm test"},
      "session_id": "abc123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.preview == #"Bash {"command":"npm test"}"#)
}

@Test
func qoderClientMetadataCanBeInjectedFromBridgeArguments() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "qoder-123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoder", "--client-name", "Qoder"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.metadata["client_kind"] == "qoder")
    #expect(envelope.metadata["client_name"] == "Qoder")
    #expect(envelope.sessionKey == "claude:qoder-123")
}

@Test
func qoderPreToolUseQuestionUsesWaitingForInputWithoutBlockingHook() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-questions",
      "tool_name": "ask_user_question",
      "tool_input": {
        "questions": [
          {
            "header": "开发领域",
            "question": "您目前主要从事哪个领域的开发工作?",
            "options": [{"label": "前端/后端开发"}]
          },
          {
            "header": "编程语言",
            "question": "您最常使用的编程语言是什么?",
            "options": [{"label": "Python"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoder"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse == false)
    #expect(envelope.intervention == nil)
    #expect(envelope.metadata["tool_input_json"]?.contains("\"questions\"") == true)
    #expect(envelope.metadata["tool_name"] == "ask_user_question")
}

@Test
func qoderWorkClientMetadataCanBeInjectedFromBridgeArguments() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "qoderwork-123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoderwork", "--client-name", "QoderWork"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.metadata["client_kind"] == "qoderwork")
    #expect(envelope.metadata["client_name"] == "QoderWork")
    #expect(envelope.sessionKey == "claude:qoderwork-123")
}

@Test
func qoderWorkPreToolUseQuestionSurfacesVisibleIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoderwork-questions",
      "tool_name": "ask_user_question",
      "tool_input": {
        "questions": [
          {
            "header": "开发领域",
            "question": "您目前主要从事哪个领域的开发工作?",
            "options": [{"label": "前端/后端开发"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoderwork", "--client-name", "QoderWork"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse)
    #expect(envelope.intervention?.kind == .question)
    #expect(envelope.metadata["tool_input_json"]?.contains("\"questions\"") == true)
    #expect(envelope.metadata["tool_name"] == "ask_user_question")
}

@Test
func qoderWorkPostToolUseResolvedQuestionDoesNotCreateNewIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PostToolUse",
      "session_id": "qoderwork-resolved-question",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "偏好",
            "question": "您最喜欢使用哪种编程语言进行开发?",
            "options": [{"label": "Python (推荐)"}]
          }
        ]
      },
      "tool_response": "User has answered your questions: \\"您最喜欢使用哪种编程语言进行开发?\\"=\\"Python (推荐)\\"."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoderwork", "--client-name", "QoderWork"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PostToolUse")
    #expect(envelope.status?.kind == .active)
    #expect(envelope.expectsResponse == false)
    #expect(envelope.intervention == nil)
    #expect(envelope.metadata["tool_response"]?.contains("Python (推荐)") == true)
}

@Test
func qoderWorkPermissionRequestQuestionStillMapsToQuestionIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "qoderwork-permission-question",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "技能",
            "question": "你最想了解 QoderWork 的哪个功能或技能？",
            "options": [{"label": "MCP 工具集成"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoderwork", "--client-name", "QoderWork"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse)
    #expect(envelope.intervention?.kind == .question)
}

@Test
func qoderWorkPromptPreviewStripsSystemReminderBlocks() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "qoderwork-preview",
      "prompt": "使用工具问我2个问题\\n\\n<system-reminder>\\nUser environment\\n</system-reminder>\\n<system-reminder>\\nAvailable MCP servers\\n</system-reminder>"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoderwork", "--client-name", "QoderWork"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.preview == "使用工具问我2个问题")
}

@Test
func qoderWorkAnswerPayloadUsesHookSpecificUpdatedInput() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "answers": .object([
                "interest": .string("人工智能")
            ])
        ]
    )
    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PreToolUse",
        metadata: ["client_kind": "qoderwork", "client_name": "QoderWork"]
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PreToolUse")
    #expect(hookSpecificOutput["permissionDecision"] as? String == "allow")
    let updatedInput = try #require(hookSpecificOutput["updatedInput"] as? [String: Any])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(answers["interest"] == "人工智能")
}

@Test
func qoderWorkPermissionRequestAnswerPayloadUsesMatchingHookEventName() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "answers": .object([
                "weekend": .string("阅读与学习")
            ])
        ]
    )
    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PermissionRequest",
        metadata: ["client_kind": "qoderwork", "client_name": "QoderWork"]
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    #expect(hookSpecificOutput["permissionDecision"] as? String == "allow")
}
