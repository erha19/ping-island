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
func mapsGhosttyTerminalContextFromEnvironment() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "ghostty-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "ghostty",
            "TERM_SESSION_ID": "ghostty-terminal-1",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "ghostty")
    #expect(envelope.terminalContext.terminalBundleID == "com.mitchellh.ghostty")
    #expect(envelope.terminalContext.terminalSessionID == "ghostty-terminal-1")
}

@Test
func mapsWezTermTerminalContextFromEnvironment() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "wezterm-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "WezTerm", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "WezTerm")
    #expect(envelope.terminalContext.terminalBundleID == "com.github.wez.wezterm")
}

@Test
func mapsClaudeIDEAndRemoteContextFromEnvironment() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "cursor-remote-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "vscode",
            "CURSOR_TRACE_ID": "trace-1",
            "VSCODE_REMOTE_AUTHORITY": "ssh-remote+devbox",
            "PWD": "/tmp/demo",
            "TMUX": "/tmp/tmux-100/default,123,0",
            "TMUX_PANE": "%3"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "vscode")
    #expect(envelope.terminalContext.terminalBundleID == "com.todesktop.230313mzl4w4u92")
    #expect(envelope.terminalContext.ideName == "Cursor")
    #expect(envelope.terminalContext.ideBundleID == "com.todesktop.230313mzl4w4u92")
    #expect(envelope.terminalContext.transport == "ssh-remote")
    #expect(envelope.terminalContext.remoteHost == "devbox")
    #expect(envelope.terminalContext.tmuxSession == "/tmp/tmux-100/default,123,0")
    #expect(envelope.terminalContext.tmuxPane == "%3")
    #expect(envelope.metadata["client_originator"] == "Cursor")
    #expect(envelope.metadata["connection_transport"] == "ssh-remote")
    #expect(envelope.metadata["remote_host"] == "devbox")
}

@Test
func mapsQoderIDEContextAheadOfGenericVSCodeDetection() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "qoder-ide-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoder", "--client-name", "Qoder", "--client-originator", "Qoder"],
        environment: [
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.qoder.ide",
            "VSCODE_GIT_IPC_HANDLE": "/Applications/Qoder.app/Contents/Resources/app/out/vs/workbench",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "vscode")
    #expect(envelope.terminalContext.terminalBundleID == "com.qoder.ide")
    #expect(envelope.terminalContext.ideName == "Qoder")
    #expect(envelope.terminalContext.ideBundleID == "com.qoder.ide")
    #expect(envelope.metadata["client_originator"] == "Qoder")
    #expect(envelope.metadata["terminal_bundle_id"] == "com.qoder.ide")
}

@Test
func explicitBridgeOriginatorOverridesGenericVSCodeInference() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "qoder-override-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoder", "--client-name", "Qoder", "--client-originator", "Qoder"],
        environment: [
            "TERM_PROGRAM": "vscode",
            "VSCODE_GIT_IPC_HANDLE": "/tmp/vscode-ipc",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.ideName == "VS Code")
    #expect(envelope.metadata["client_originator"] == "Qoder")
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
func claudeQuestionAnswerPayloadPreservesFullUpdatedInputForPermissionRequests() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "questions": .array([
                .object([
                    "id": .string("terminal_scope"),
                    "question": .string("Which terminal?"),
                    "options": .array([
                        .object(["label": .string("iTerm2")]),
                        .object(["label": .string("Terminal")])
                    ])
                ])
            ]),
            "answers": .object([
                "Which terminal?": .string("iTerm2")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PermissionRequest",
        metadata: [:]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")

    let updatedInput = try #require(decision["updatedInput"] as? [String: Any])
    let questions = try #require(updatedInput["questions"] as? [[String: Any]])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(questions.first?["question"] as? String == "Which terminal?")
    #expect(answers["Which terminal?"] == "iTerm2")
}

@Test
func claudeUserInputAnswerPayloadPreservesFullUpdatedInput() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "questions": .array([
                .object([
                    "question": .string("Which terminal?")
                ])
            ]),
            "answers": .object([
                "Which terminal?": .string("iTerm2")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "UserInputRequest",
        metadata: [:]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["permissionDecision"] as? String == "allow")

    let updatedInput = try #require(hookSpecificOutput["updatedInput"] as? [String: Any])
    let questions = try #require(updatedInput["questions"] as? [[String: Any]])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(questions.first?["question"] as? String == "Which terminal?")
    #expect(answers["Which terminal?"] == "iTerm2")
}

@Test
func claudeNonQuestionAnswerPayloadKeepsLegacyFlattenedShape() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([
            "terminal_scope": "iTerm2"
        ]),
        updatedInput: [
            "answers": .object([
                "terminal_scope": .string("iTerm2")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PermissionRequest",
        metadata: ["tool_name": "Bash"]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    let updatedInput = try #require(decision["updatedInput"] as? [String: String])
    #expect(updatedInput["terminal_scope"] == "iTerm2")
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
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoder", "--client-name", "Qoder", "--client-originator", "Qoder"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.metadata["client_kind"] == "qoder")
    #expect(envelope.metadata["client_name"] == "Qoder")
    #expect(envelope.metadata["client_originator"] == "Qoder")
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
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "qoderwork", "--client-name", "QoderWork", "--client-originator", "QoderWork"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.metadata["client_kind"] == "qoderwork")
    #expect(envelope.metadata["client_name"] == "QoderWork")
    #expect(envelope.metadata["client_originator"] == "QoderWork")
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
func claudePostToolUseResolvedQuestionDoesNotKeepSocketOpen() throws {
    let payload = """
    {
      "hook_event_name": "PostToolUse",
      "session_id": "claude-resolved-question",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "任务",
            "question": "你想先处理哪个部分？",
            "options": [{"label": "SessionStore"}]
          }
        ],
        "answers": {
          "你想先处理哪个部分？": "SessionStore"
        }
      },
      "tool_response": {
        "questions": [
          {
            "header": "任务",
            "question": "你想先处理哪个部分？",
            "options": [{"label": "SessionStore"}]
          }
        ],
        "answers": {
          "你想先处理哪个部分？": "SessionStore"
        }
      },
      "transcript_path": "/tmp/claude-resolved-question.jsonl"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PostToolUse")
    #expect(envelope.status?.kind == .active)
    #expect(envelope.expectsResponse == false)
    #expect(envelope.intervention == nil)
    #expect(envelope.metadata["tool_response"]?.contains("SessionStore") == true)
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

@Test
func geminiBeforeToolMapsToRunningToolWithoutIntervention() throws {
    let payload = """
    {
      "hook_event_name": "BeforeTool",
      "tool_name": "write_file",
      "tool_input": {"path": "/tmp/demo.swift"},
      "session_id": "gemini-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "gemini",
            "--client-name", "Gemini CLI"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "BeforeTool")
    #expect(envelope.status?.kind == .runningTool)
    #expect(envelope.intervention == nil)
    #expect(envelope.expectsResponse == false)
    #expect(envelope.metadata["client_kind"] == "gemini")
}

@Test
func geminiNotificationStaysObservabilityOnly() throws {
    let payload = """
    {
      "hook_event_name": "Notification",
      "notification_type": "ToolPermission",
      "message": "Gemini CLI is asking for tool permission",
      "details": {"tool_name": "write_file"},
      "session_id": "gemini-2"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "gemini",
            "--client-name", "Gemini CLI"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Notification")
    #expect(envelope.status?.kind == .notification)
    #expect(envelope.intervention == nil)
    #expect(envelope.expectsResponse == false)
}

@Test
func mapsCopilotPreToolUsePayloadFromOfficialFields() throws {
    let payload = """
    {
      "sessionId": "copilot-1",
      "toolName": "edit_file",
      "toolArgs": "{\\"path\\":\\"/tmp/demo.swift\\",\\"replace\\":\\"hello\\"}",
      "cwd": "/tmp/demo"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .copilot,
        arguments: ["island-bridge", "--source", "copilot", "--event", "preToolUse"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .copilot)
    #expect(envelope.eventType == "preToolUse")
    #expect(envelope.sessionKey == "copilot:copilot-1")
    #expect(envelope.title == "edit_file")
    #expect(envelope.preview == #"edit_file {"path":"/tmp/demo.swift","replace":"hello"}"#)
    #expect(envelope.status?.kind == .runningTool)
    #expect(envelope.metadata["tool_name"] == "edit_file")
    #expect(envelope.metadata["tool_input_json"] == #"{"path":"/tmp/demo.swift","replace":"hello"}"#)
}

@Test
func mapsCopilotSessionStartFromEventFlagAndPrompt() throws {
    let payload = """
    {
      "initialPrompt": "Audit the bridge hooks",
      "cwd": "/tmp/copilot"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .copilot,
        arguments: ["island-bridge", "--source", "copilot", "--event", "sessionStart"],
        environment: ["PWD": "/tmp/copilot"],
        stdinData: payload
    )

    #expect(envelope.eventType == "sessionStart")
    #expect(envelope.preview == "Audit the bridge hooks")
    #expect(envelope.cwd == "/tmp/copilot")
    #expect(envelope.status?.kind == .thinking)
}

@Test
func copilotStdoutPayloadUsesPermissionDecisionAndModifiedArgs() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "path": .string("/tmp/demo.swift"),
            "replace": .string("updated")
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .copilot,
        response: response,
        eventType: "preToolUse",
        metadata: [:]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    #expect(json["permissionDecision"] as? String == "allow")
    let modifiedArgs = try #require(json["modifiedArgs"] as? [String: String])
    #expect(modifiedArgs["path"] == "/tmp/demo.swift")
    #expect(modifiedArgs["replace"] == "updated")
}
