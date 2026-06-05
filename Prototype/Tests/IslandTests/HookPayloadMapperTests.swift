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
func routePromptsToTerminalDropsApprovalIntervention() throws {
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
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload,
        runtimeConfig: BridgeRuntimeConfig(routePromptsToTerminal: true)
    )

    #expect(envelope.intervention == nil)
    #expect(envelope.expectsResponse == false)
}

@Test
func routePromptsToTerminalDropsAskUserQuestionIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {"id": "q1", "question": "Pick one", "options": ["A", "B"]}
        ]
      },
      "session_id": "abc123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload,
        runtimeConfig: BridgeRuntimeConfig(routePromptsToTerminal: true)
    )

    #expect(envelope.intervention == nil)
    #expect(envelope.expectsResponse == false)
}

@Test
func bridgeRuntimeConfigLoadsFromEnvironmentPath() async throws {
    try await withTemporaryDirectory { directory in
        let configURL = directory.appending(path: "bridge-config.json")
        try """
        {
          "routePromptsToTerminal": true
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = BridgeRuntimeConfig.load(
            environment: [BridgeRuntimeConfig.configPathEnvironmentKey: configURL.path()]
        )

        #expect(config.routePromptsToTerminal)
    }
}

@Test
func bridgeRuntimeConfigLoadedFromEnvironmentDropsApprovalIntervention() async throws {
    try await withTemporaryDirectory { directory in
        let configURL = directory.appending(path: "bridge-config.json")
        try """
        {
          "routePromptsToTerminal": true
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let environment = [
            BridgeRuntimeConfig.configPathEnvironmentKey: configURL.path(),
            "TERM_PROGRAM": "iTerm.app",
            "PWD": "/tmp/demo"
        ]
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
            environment: environment,
            stdinData: payload,
            runtimeConfig: BridgeRuntimeConfig.load(environment: environment)
        )

        #expect(envelope.intervention == nil)
        #expect(envelope.expectsResponse == false)
        #expect(envelope.metadata["suppress_in_app_prompt"] == "true")
    }
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
func mapsCmuxTerminalContextFromEnvironment() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "cmux-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "cmux",
            "TERM_SESSION_ID": "65a2028f-a93c-48e0-b46a-3f4c20c94b81",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "cmux")
    #expect(envelope.terminalContext.terminalBundleID == "com.cmuxterm.app")
    #expect(envelope.terminalContext.terminalSessionID == "65a2028f-a93c-48e0-b46a-3f4c20c94b81")
}

@Test
func opencodePermissionRequestCreatesApprovalIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "opencode-demo",
      "tool_name": "Bash",
      "tool_input": {
        "command": "npm test"
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "opencode",
            "--client-name", "OpenCode",
            "--thread-source", "opencode-plugin"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.metadata["client_kind"] == "opencode")
}

@Test
func opencodeQuestionRequestCreatesQuestionIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "opencode-question",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "id": "scope",
            "header": "范围",
            "question": "你想先处理哪一块？",
            "options": [{"label": "Hooks"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "opencode",
            "--client-name", "OpenCode",
            "--thread-source", "opencode-plugin"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse)
    #expect(envelope.intervention?.kind == .question)
    #expect(envelope.intervention?.message == "你想先处理哪一块？")
    #expect(envelope.metadata["tool_name"] == "AskUserQuestion")
}

@Test
func opencodeBridgePayloadEnvironmentOverridesTerminalContext() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "opencode-env",
      "_tty": "/dev/ttys009",
      "_env": {
        "TERM_PROGRAM": "ghostty",
        "TMUX_PANE": "%42",
        "__CFBundleIdentifier": "com.mitchellh.ghostty"
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "opencode",
            "--client-name", "OpenCode"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "ghostty")
    #expect(envelope.terminalContext.terminalBundleID == "com.mitchellh.ghostty")
    #expect(envelope.terminalContext.tmuxPane == "%42")
    #expect(envelope.terminalContext.tty == "/dev/ttys009")
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
func doesNotInferCodexAppBundleFromCodexCliTerminalProgram() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "codex-cli-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .codex,
        arguments: ["island-bridge", "--source", "codex"],
        environment: [
            "TERM_PROGRAM": "codex",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "codex")
    #expect(envelope.terminalContext.terminalBundleID == nil)
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
func recoversCursorWorkspaceFromAgentTranscriptPathWhenPWDIsClientConfig() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("pingislandcursor\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", isDirectory: true)
    let workspaceURL = tempRoot.appendingPathComponent("Island", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let workspacePath = workspaceURL.standardizedFileURL.path
    let projectSlug = workspacePath
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: "-")
    let transcriptPath = "/synthetic/.cursor/projects/\(projectSlug)/agent-transcripts/cursor-session/cursor-session.jsonl"
    let payload = """
    {
      "hook_event_name": "SessionStart",
      "session_id": "cursor-session",
      "transcript_path": "\(transcriptPath)"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "cursor",
            "--client-name", "Cursor",
            "--client-originator", "Cursor"
        ],
        environment: [
            "PWD": "/synthetic/.cursor",
            "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"
        ],
        stdinData: payload
    )

    #expect(envelope.cwd == workspacePath)
    #expect(envelope.terminalContext.currentDirectory == workspacePath)
    #expect(envelope.metadata["cwd"] == workspacePath)
}

@Test
func keepsExplicitWorkspaceWhenCursorTranscriptPathAlsoExists() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("pingislandcursor\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", isDirectory: true)
    let workspaceURL = tempRoot.appendingPathComponent("Island", isDirectory: true)
    let explicitURL = tempRoot.appendingPathComponent("Explicit", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: explicitURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let workspacePath = workspaceURL.standardizedFileURL.path
    let explicitPath = explicitURL.standardizedFileURL.path
    let projectSlug = workspacePath
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: "-")
    let transcriptPath = "/synthetic/.cursor/projects/\(projectSlug)/agent-transcripts/cursor-session/cursor-session.jsonl"
    let payload = """
    {
      "hook_event_name": "SessionStart",
      "session_id": "cursor-session",
      "cwd": "\(explicitPath)",
      "transcript_path": "\(transcriptPath)"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude", "--client-kind", "cursor"],
        environment: ["PWD": "/synthetic/.cursor"],
        stdinData: payload
    )

    #expect(envelope.cwd == explicitPath)
    #expect(envelope.metadata["cwd"] == explicitPath)
}

@Test
func mapsSSHRemoteHostFromHostnameEnvironmentBeforeConnectionIP() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "ssh-hostname-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "SSH_CONNECTION": "192.168.1.2 49822 10.0.0.10 22",
            "HOSTNAME": "devbox",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.transport == "ssh")
    #expect(envelope.terminalContext.remoteHost == "devbox")
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
func codexPermissionPayloadUsesLatestHookSpecificOutput() throws {
    let payload = HookPayloadMapper.stdoutPayload(
        for: .codex,
        response: BridgeResponse(requestID: UUID(), decision: .approve),
        eventType: "PermissionRequest",
        metadata: [:]
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )

    #expect(json["decision"] == nil)
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
func bridgeAnswerPayloadExtractsNestedAnswersForRemoteQuestionResponses() {
    let extracted = BridgeAnswerPayload.extractAnswers(from: [
        "questions": .array([
            .object([
                "id": .string("terminal_scope"),
                "question": .string("Which terminal?")
            ])
        ]),
        "answers": .object([
            "Which terminal?": .string("iTerm2"),
            "selection_index": .int(1),
            "confirmed": .bool(true),
            "choices": .array([
                .string("iTerm2"),
                .string("Terminal")
            ])
        ])
    ])

    #expect(extracted["Which terminal?"] == "iTerm2")
    #expect(extracted["selection_index"] == "1")
    #expect(extracted["confirmed"] == "true")
    #expect(extracted["choices"] == "iTerm2, Terminal")
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
func qoderCLIClientMetadataCanBeInjectedFromBridgeArguments() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "qoder-cli-123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "qoder-cli",
            "--client-name", "Qoder CLI",
            "--client-origin", "cli",
            "--client-originator", "Qoder"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.metadata["client_kind"] == "qoder-cli")
    #expect(envelope.metadata["client_name"] == "Qoder CLI")
    #expect(envelope.metadata["client_origin"] == "cli")
    #expect(envelope.metadata["client_originator"] == "Qoder")
    #expect(envelope.sessionKey == "claude:qoder-cli-123")
}

@Test
func codeBuddyCLIClientMetadataCanBeInjectedFromBridgeArguments() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "codebuddy-cli-123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "codebuddy-cli",
            "--client-name", "CodeBuddy CLI",
            "--client-origin", "cli",
            "--client-originator", "CodeBuddy"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.metadata["client_kind"] == "codebuddy-cli")
    #expect(envelope.metadata["client_name"] == "CodeBuddy CLI")
    #expect(envelope.metadata["client_origin"] == "cli")
    #expect(envelope.metadata["client_originator"] == "CodeBuddy")
    #expect(envelope.sessionKey == "claude:codebuddy-cli-123")
}

@Test
func codeBuddyCLIPreToolUseBecomesBlockingApproval() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "codebuddy-cli-tool",
      "permission_mode": "default",
      "tool_name": "Write",
      "tool_input": {
        "file_path": "/tmp/demo.txt",
        "content": "hello"
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "codebuddy-cli",
            "--client-name", "CodeBuddy CLI",
            "--client-origin", "cli",
            "--client-originator", "CodeBuddy"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.intervention?.title == "CodeBuddy CLI needs approval")
}

@Test
func codeBuddyCLIAskUserQuestionNotificationKeepsBridgeResponseOpen() throws {
    let payload = """
    {
      "hook_event_name": "Notification",
      "session_id": "codebuddy-cli-question",
      "notification_type": "permission_prompt",
      "message": "needs your permission to use AskUserQuestion"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "codebuddy-cli",
            "--client-name", "CodeBuddy CLI",
            "--client-origin", "cli",
            "--client-originator", "CodeBuddy"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Notification")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.metadata["client_kind"] == "codebuddy-cli")
}

@Test
func codeBuddyCLIPermissionRequestAskUserQuestionBecomesInlineQuestion() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "codebuddy-cli-question",
      "tool_name": "AskUserQuestion",
      "tool_use_id": "call_question",
      "tool_input": {
        "questions": [
          {
            "id": "scope",
            "header": "Scope",
            "question": "Where should we start?",
            "options": [
              {"label": "SessionStore"},
              {"label": "UI"}
            ]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "codebuddy-cli",
            "--client-name", "CodeBuddy CLI",
            "--client-origin", "cli",
            "--client-originator", "CodeBuddy"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .question)
    #expect(envelope.intervention?.rawContext["tool_use_id"] == "call_question")
    #expect(envelope.metadata["tool_input_json"]?.contains("Where should we start?") == true)
}

@Test
func piAgentClientMetadataCanBeInjectedFromBridgeArguments() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "pi-session-123",
      "prompt": "Map the repo and suggest the next edit."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "pi",
            "--client-name", "Pi Agent",
            "--client-origin", "cli",
            "--client-originator", "Pi",
            "--thread-source", "pi-extension"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .claude)
    #expect(envelope.eventType == "UserPromptSubmit")
    #expect(envelope.sessionKey == "claude:pi-session-123")
    #expect(envelope.preview == "Map the repo and suggest the next edit.")
    #expect(envelope.metadata["client_kind"] == "pi")
    #expect(envelope.metadata["client_name"] == "Pi Agent")
    #expect(envelope.metadata["client_origin"] == "cli")
    #expect(envelope.metadata["client_originator"] == "Pi")
    #expect(envelope.metadata["thread_source"] == "pi-extension")
}

@Test
func piAgentPreToolUseMapsToolPayload() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "pi-tool",
      "tool_name": "Write",
      "tool_input": {
        "file_path": "/tmp/demo.txt",
        "content": "hello"
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "pi",
            "--client-name", "Pi Agent",
            "--client-origin", "cli",
            "--client-originator", "Pi",
            "--thread-source", "pi-extension"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .runningTool)
    #expect(envelope.metadata["tool_name"] == "Write")
    #expect(envelope.metadata["tool_input_json"]?.contains("/tmp/demo.txt") == true)
}

@Test
func piAgentPermissionRequestUsesPiApprovalTitle() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "pi-permission",
      "tool_name": "Bash",
      "tool_input": {
        "command": "sudo make install"
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge", "--source", "claude",
            "--client-kind", "pi",
            "--client-name", "Pi Agent",
            "--client-origin", "cli",
            "--client-originator", "Pi",
            "--thread-source", "pi-extension"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.intervention?.title == "Pi Agent needs approval")
    #expect(envelope.intervention?.message == "Bash")
}

@Test
func qoderCLIExitPlanModePreToolUseBecomesBlockingApproval() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-cli-plan",
      "permission_mode": "plan",
      "tool_name": "ExitPlanMode",
      "tool_input": {
        "plan": "# Plan\\nImplement the requested feature.",
        "allowedPrompts": [{"tool": "Bash", "prompt": "Run tests"}]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder-cli",
            "--client-name", "Qoder CLI",
            "--client-origin", "cli",
            "--client-originator", "Qoder"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.intervention?.title == "Qoder CLI needs plan approval")
    #expect(envelope.intervention?.message.contains("Implement the requested feature.") == true)
    #expect(envelope.metadata["tool_input_json"]?.contains("allowedPrompts") == true)
    #expect(envelope.preview?.hasPrefix("ExitPlanMode ") == true)
}

@Test
func qoderCLIExitPlanModeDefaultPermissionModeStillBlocksForReview() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-cli-default-plan",
      "permission_mode": "default",
      "tool_name": "ExitPlanMode",
      "tool_input": {}
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder-cli",
            "--client-name", "Qoder CLI",
            "--client-origin", "cli",
            "--client-originator", "Qoder"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.intervention?.title == "Qoder CLI needs plan approval")
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
func qoderCLIHooksExecutedInsideQoderIDEStayNotifyOnly() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-ide-question",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "Next Step",
            "question": "What should happen inside Qoder IDE?",
            "options": [{"label": "Stay notify only"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder-cli",
            "--client-name", "Qoder CLI",
            "--client-origin", "cli",
            "--client-originator", "Qoder"
        ],
        environment: [
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.qoder.ide",
            "VSCODE_GIT_IPC_HANDLE": "/Applications/Qoder.app/Contents/Resources/app/out/vs/workbench",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder-cli")
    #expect(envelope.metadata["terminal_bundle_id"] == "com.qoder.ide")
    #expect(envelope.expectsResponse == false)
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.intervention == nil)
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
}

@Test
func claudeHooksExecutedInsideQoderIDETerminalKeepClaudeApprovalOptions() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "claude-in-qoder-ide",
      "tool_name": "Bash",
      "tool_input": {
        "command": "npm test"
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: [
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.qoder.ide",
            "VSCODE_GIT_IPC_HANDLE": "/Applications/Qoder.app/Contents/Resources/app/out/vs/workbench",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == nil)
    #expect(envelope.metadata["terminal_bundle_id"] == "com.qoder.ide")
    #expect(envelope.expectsResponse)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.intervention?.options.map(\.id) == ["approve", "approveForSession", "deny"])
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
}

@Test
func qoderCLINonQuestionHooksExecutedInsideQoderIDESkipDelivery() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-ide-bash",
      "tool_name": "Bash",
      "tool_input": {
        "command": "pwd"
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder-cli",
            "--client-name", "Qoder CLI",
            "--client-origin", "cli",
            "--client-originator", "Qoder"
        ],
        environment: [
            "__CFBundleIdentifier": "com.qoder.ide",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder-cli")
    #expect(envelope.metadata["terminal_bundle_id"] == "com.qoder.ide")
    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.expectsResponse == false)
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope) == false)
}

@Test
func qoderCLIHooksExecutedInsideQoderIDEStillForwardCompletion() throws {
    let payload = """
    {
      "hook_event_name": "Stop",
      "session_id": "qoder-ide-stop",
      "last_assistant_message": "Done from Qoder IDE."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder-cli",
            "--client-name", "Qoder CLI",
            "--client-origin", "cli",
            "--client-originator", "Qoder"
        ],
        environment: [
            "__CFBundleIdentifier": "com.qoder.ide",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder-cli")
    #expect(envelope.metadata["terminal_bundle_id"] == "com.qoder.ide")
    #expect(envelope.eventType == "Stop")
    #expect(envelope.expectsResponse == false)
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
}

@Test
func qoderIDEPermissionRequestForwardsQuestionNotification() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "qoder-ide-native-question",
      "tool_name": "ask_user_question",
      "tool_input": {
        "question": "Pick the next action",
        "questions": [
          {
            "header": "Next Step",
            "question": "What should happen inside Qoder IDE?",
            "options": [{"label": "Use IDE card"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder",
            "--client-name", "Qoder",
            "--client-originator", "Qoder"
        ],
        environment: [
            "__CFBundleIdentifier": "com.qoder.ide",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder")
    #expect(envelope.metadata["terminal_bundle_id"] == "com.qoder.ide")
    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.expectsResponse == false)
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.intervention == nil)
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
}

@Test
func qoderIDEAnsweredQuestionForwardsCleanupWithoutNewIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-ide-native-answer",
      "tool_name": "ask_user_question",
      "tool_input": {
        "questions": [
          {
            "header": "Next Step",
            "question": "What should happen inside Qoder IDE?",
            "options": [{"label": "Use IDE card"}]
          }
        ],
        "answers": {
          "What should happen inside Qoder IDE?": "Use IDE card"
        }
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder",
            "--client-name", "Qoder",
            "--client-originator", "Qoder"
        ],
        environment: [
            "__CFBundleIdentifier": "com.qoder.ide",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder")
    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.expectsResponse == false)
    #expect(envelope.status?.kind == .runningTool)
    #expect(envelope.intervention == nil)
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
}

@Test
func qoderIDEPostToolUseResolvedQuestionForwardsCleanup() throws {
    let payload = """
    {
      "hook_event_name": "PostToolUse",
      "session_id": "qoder-ide-native-post-answer",
      "tool_name": "ask_user_question",
      "tool_input": {
        "questions": [
          {
            "header": "Next Step",
            "question": "What should happen inside Qoder IDE?",
            "options": [{"label": "Use IDE card"}]
          }
        ]
      },
      "tool_response": "User has answered your questions."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder",
            "--client-name", "Qoder",
            "--client-originator", "Qoder"
        ],
        environment: [
            "__CFBundleIdentifier": "com.qoder.ide",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder")
    #expect(envelope.eventType == "PostToolUse")
    #expect(envelope.expectsResponse == false)
    #expect(envelope.status?.kind == .active)
    #expect(envelope.intervention == nil)
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
}

@Test
func qoderIDEStillForwardsCompletion() throws {
    let payload = """
    {
      "hook_event_name": "Stop",
      "session_id": "qoder-ide-native-stop",
      "last_assistant_message": "Done from Qoder IDE."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder",
            "--client-name", "Qoder",
            "--client-originator", "Qoder"
        ],
        environment: [
            "__CFBundleIdentifier": "com.qoder.ide",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder")
    #expect(envelope.metadata["terminal_bundle_id"] == "com.qoder.ide")
    #expect(envelope.eventType == "Stop")
    #expect(envelope.expectsResponse == false)
    #expect(HookPayloadMapper.shouldDeliverEnvelope(envelope))
}

@Test
func legacyQoderCLIHookMetadataStillSurfacesClaudeCompatibleIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-cli-legacy-kind",
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
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder",
            "--client-name", "Qoder CLI",
            "--client-origin", "cli",
            "--client-originator", "Qoder"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.metadata["client_kind"] == "qoder")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .question)
}

@Test
func qoderIDEProcessMetadataDoesNotPromoteToQoderCLI() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-cli-legacy-process",
      "source_process_name": "/Users/example/.qoder/bin/qodercli/qodercli-0.2.5",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "Next Step",
            "question": "What would you like to do first?",
            "options": [{"label": "Read a file"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let notifyOnlyPayload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qoder-cli-legacy-process",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "Next Step",
            "question": "What would you like to do first?",
            "options": [{"label": "Read a file"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder",
            "--client-name", "Qoder",
            "--client-originator", "Qoder"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: notifyOnlyPayload
    )

    let envelopeWithProcess = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qoder",
            "--client-name", "Qoder",
            "--client-originator", "Qoder"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.expectsResponse == false)
    #expect(envelopeWithProcess.status?.kind == .waitingForInput)
    #expect(envelopeWithProcess.expectsResponse == false)
    #expect(envelopeWithProcess.intervention == nil)
}

@Test
func qoderCLIAnswerPayloadIncludesTopLevelUpdatedInputForQoderParser() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "questions": .array([
                .object([
                    "question": .string("Which model?"),
                    "options": .array([
                        .object(["label": .string("Lite")]),
                        .object(["label": .string("Pro")])
                    ])
                ])
            ]),
            "answers": .object([
                "Which model?": .string("Pro")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PreToolUse",
        metadata: ["client_kind": "qoder-cli", "client_name": "Qoder CLI", "tool_name": "AskUserQuestion"]
    )
    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PreToolUse")
    #expect(hookSpecificOutput["permissionDecision"] as? String == "allow")
    let topLevelUpdatedInput = try #require(hookSpecificOutput["updatedInput"] as? [String: Any])
    let topLevelAnswers = try #require(topLevelUpdatedInput["answers"] as? [String: String])
    #expect(topLevelAnswers["Which model?"] == "Pro")
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    let updatedInput = try #require(decision["updatedInput"] as? [String: Any])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(answers["Which model?"] == "Pro")
}

@Test
func qoderCLIExitPlanModeApprovalPayloadUsesPreToolUseEventName() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .approve
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PreToolUse",
        metadata: [
            "client_kind": "qoder-cli",
            "client_name": "Qoder CLI",
            "permission_mode": "default",
            "tool_name": "ExitPlanMode"
        ]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PreToolUse")
    #expect(hookSpecificOutput["permissionDecision"] as? String == "allow")
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
}

@Test
func codeBuddyCLIApprovalPayloadUsesClaudeCodeOutputShape() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .approve
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PreToolUse",
        metadata: [
            "client_kind": "codebuddy-cli",
            "client_name": "CodeBuddy CLI",
            "tool_name": "Write"
        ]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    #expect(hookSpecificOutput["permissionDecision"] == nil)
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
}

@Test
func codeBuddyCLIPermissionRequestAnswerPayloadUsesClaudeCodeOutputShape() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "questions": .array([
                .object([
                    "id": .string("scope"),
                    "question": .string("Where should we start?"),
                    "options": .array([
                        .object(["label": .string("SessionStore")])
                    ])
                ])
            ]),
            "answers": .object([
                "scope": .string("SessionStore")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PermissionRequest",
        metadata: [
            "client_kind": "codebuddy-cli",
            "client_name": "CodeBuddy CLI"
        ]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    #expect(hookSpecificOutput["permissionDecision"] == nil)
    #expect(hookSpecificOutput["modifiedInput"] == nil)
    #expect(hookSpecificOutput["updatedInput"] == nil)
    #expect(json["decision"] == nil)
    #expect(json["modifiedInput"] == nil)
    #expect(json["updatedInput"] == nil)
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    let updatedInput = try #require(decision["updatedInput"] as? [String: Any])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(answers["scope"] == "SessionStore")
}

@Test
func codeBuddyCLINotificationAnswerPayloadUsesClaudeCodeOutputShape() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "questions": .array([
                .object([
                    "id": .string("scope"),
                    "question": .string("Where should we start?"),
                    "options": .array([
                        .object(["label": .string("SessionStore")])
                    ])
                ])
            ]),
            "answers": .object([
                "scope": .string("SessionStore")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "Notification",
        metadata: [
            "client_kind": "codebuddy-cli",
            "client_name": "CodeBuddy CLI"
        ]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "Notification")
    #expect(hookSpecificOutput["permissionDecision"] == nil)
    #expect(hookSpecificOutput["updatedInput"] == nil)
    #expect(json["decision"] == nil)
    #expect(json["modifiedInput"] == nil)
    #expect(json["updatedInput"] == nil)
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    let updatedInput = try #require(decision["updatedInput"] as? [String: Any])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(answers["scope"] == "SessionStore")
}

@Test
func qoderCLIAnswerPayloadUsesTopLevelShapeWhenClientKindIsMissing() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "answers": .object([
                "Which model?": .string("Pro")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: response,
        eventType: "PermissionRequest",
        metadata: [
            "client_name": "Qoder CLI",
            "client_origin": "cli",
            "client_originator": "Qoder",
            "tool_name": "AskUserQuestion"
        ]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    #expect(hookSpecificOutput["permissionDecision"] as? String == "allow")
    #expect(hookSpecificOutput["updatedInput"] != nil)
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    let updatedInput = try #require(decision["updatedInput"] as? [String: Any])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(answers["Which model?"] == "Pro")
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
func qwenCodePermissionRequestQuestionMapsToQuestionIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "qwen-code-question",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "语言",
            "question": "你最喜欢哪种编程语言？",
            "options": [{"label": "Python"}]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qwen-code",
            "--client-name", "Qwen Code",
            "--thread-source", "qwen-code-hooks"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .question)
}

@Test
func qwenCodeShellPermissionRequestOffersSessionApproval() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "qwen-code-shell",
      "permission_mode": "default",
      "tool_name": "run_shell_command",
      "tool_input": {
        "command": "find /tmp -maxdepth 1 -type f"
      },
      "permission_suggestions": [
        {
          "type": "allow",
          "label": "Allow Command",
          "description": "Execute: find /tmp -maxdepth 1 -type f"
        },
        {
          "type": "deny",
          "label": "Deny",
          "description": "Block this command execution"
        }
      ]
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qwen-code",
            "--client-name", "Qwen Code",
            "--thread-source", "qwen-code-hooks"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.intervention?.options.map(\.id) == ["approve", "approveForSession", "deny"])
    #expect(envelope.metadata["permission_suggestions"]?.contains("Allow Command") == true)
}

@Test
func qwenCodeApproveForSessionPayloadUpdatesShellPermission() throws {
    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: BridgeResponse(requestID: UUID(), decision: .approveForSession),
        eventType: "PermissionRequest",
        metadata: [
            "client_kind": "qwen-code",
            "tool_name": "run_shell_command",
            "tool_input_json": #"{"command":"find /tmp -maxdepth 1 -type f"}"#
        ]
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    #expect(decision["updatedPermissions"] as? [String] == ["Bash(find /tmp -maxdepth 1 -type f)"])
}

@Test
func qwenCodeApproveOncePayloadDoesNotUpdateShellPermission() throws {
    let payload = HookPayloadMapper.stdoutPayload(
        for: .claude,
        response: BridgeResponse(requestID: UUID(), decision: .approve),
        eventType: "PermissionRequest",
        metadata: [
            "client_kind": "qwen-code",
            "tool_name": "run_shell_command",
            "tool_input_json": #"{"command":"find /tmp -maxdepth 1 -type f"}"#
        ]
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    #expect(decision["updatedPermissions"] == nil)
}

@Test
func qwenCodeNotificationPermissionPromptCreatesApprovalIntervention() throws {
    let payload = """
    {
      "hook_event_name": "Notification",
      "session_id": "qwen-code-notif-approval",
      "notification_type": "permission_prompt",
      "message": "Qwen Code wants to run Bash: ls"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qwen-code",
            "--client-name", "Qwen Code",
            "--thread-source", "qwen-code-hooks"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Notification")
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.expectsResponse == true)
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.intervention?.message.contains("Bash") == true)
}

@Test
func qwenCodeAnsweredPreToolUseDoesNotCreateAnotherIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "qwen-code-answered",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "编程语言",
            "question": "你最喜欢哪种编程语言？",
            "options": [{"label": "Python"}]
          }
        ],
        "answers": {
          "0": "Python"
        }
      },
      "status": "waiting_for_input"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qwen-code",
            "--client-name", "Qwen Code",
            "--thread-source", "qwen-code-hooks"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PreToolUse")
    #expect(envelope.status?.kind == .runningTool)
    #expect(envelope.expectsResponse == false)
    #expect(envelope.intervention == nil)
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
func qwenCodeNotificationMapsFromOfficialHookFields() throws {
    let payload = """
    {
      "hook_event_name": "Notification",
      "notification_type": "idle_prompt",
      "message": "Qwen Code is waiting for your next prompt",
      "title": "Need Input",
      "session_id": "qwen-code-1",
      "transcript_path": "/tmp/qwen-code-1.jsonl"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qwen-code",
            "--client-name", "Qwen Code",
            "--thread-source", "qwen-code-hooks"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Notification")
    #expect(envelope.status?.kind == .notification)
    #expect(envelope.preview == "Qwen Code is waiting for your next prompt")
    #expect(envelope.metadata["notification_type"] == "idle_prompt")
    #expect(envelope.metadata["transcript_path"] == "/tmp/qwen-code-1.jsonl")
    #expect(envelope.metadata["client_kind"] == "qwen-code")
}

@Test
func qwenCodeStopUsesLastAssistantMessageAsPreview() throws {
    let payload = """
    {
      "hook_event_name": "Stop",
      "session_id": "qwen-code-2",
      "last_assistant_message": "Done. I updated the files and left notes in the summary."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "qwen-code",
            "--client-name", "Qwen Code",
            "--thread-source", "qwen-code-hooks"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Stop")
    // Updated by fix-claude-sound-triggers: Stop now means "agent turn ended,
    // ready for user input" for every shared-.claude client (was .completed
    // pre-fix, which incorrectly killed the session).
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.preview == "Done. I updated the files and left notes in the summary.")
}

@Test
func hermesUserPromptSubmitMapsFromPluginHookPayload() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "hermes-1",
      "prompt": "Summarize the failing tests and next fix."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "hermes",
            "--client-name", "Hermes",
            "--thread-source", "hermes-plugin"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "UserPromptSubmit")
    #expect(envelope.status?.kind == .thinking)
    #expect(envelope.preview == "Summarize the failing tests and next fix.")
    #expect(envelope.metadata["client_kind"] == "hermes")
}

@Test
func hermesStopUsesLastAssistantMessageAsPreview() throws {
    let payload = """
    {
      "hook_event_name": "Stop",
      "session_id": "hermes-2",
      "last_assistant_message": "Done. I inspected the tool calls and wrote the follow-up notes."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "hermes-agent",
            "--client-name", "Hermes Agent",
            "--thread-source", "hermes-plugin"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Stop")
    // Updated by fix-claude-sound-triggers: Stop now means "agent turn ended,
    // ready for user input" for every shared-.claude client.
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.preview == "Done. I inspected the tool calls and wrote the follow-up notes.")
}

@Test
func hermesSessionFinalizeUsesSessionEndPreview() throws {
    let payload = """
    {
      "hook_event_name": "SessionEnd",
      "session_id": "hermes-3",
      "last_assistant_message": "Done. I inspected the tool calls and wrote the follow-up notes."
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: [
            "island-bridge",
            "--source", "claude",
            "--client-kind", "hermes-agent",
            "--client-name", "Hermes Agent",
            "--thread-source", "hermes-plugin"
        ],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "SessionEnd")
    #expect(envelope.status?.kind == .completed)
    #expect(envelope.preview == "Done. I inspected the tool calls and wrote the follow-up notes.")
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

// MARK: - Stop family mapping (fix-claude-sound-triggers)

@Test
func claudeStopMapsToWaitingForInput() throws {
    let payload = """
    {
      "hook_event_name": "Stop",
      "session_id": "claude-stop-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Stop")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.intervention == nil)
}

@Test
func claudeSubagentStopMapsToRunningTool() throws {
    let payload = """
    {
      "hook_event_name": "SubagentStop",
      "session_id": "claude-subagent-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "SubagentStop")
    #expect(envelope.status?.kind == .runningTool)
}

@Test
func claudeSubagentStartMapsToRunningTool() throws {
    let payload = """
    {
      "hook_event_name": "SubagentStart",
      "session_id": "claude-subagent-2"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "SubagentStart")
    #expect(envelope.status?.kind == .runningTool)
}

@Test
func claudeStopFailureMapsToWaitingForInput() throws {
    let payload = """
    {
      "hook_event_name": "StopFailure",
      "session_id": "claude-stopfail-1",
      "error": "rate_limit"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "StopFailure")
    #expect(envelope.status?.kind == .waitingForInput)
}

@Test
func claudeSessionEndMapsToCompleted() throws {
    let payload = """
    {
      "hook_event_name": "SessionEnd",
      "session_id": "claude-end-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "SessionEnd")
    #expect(envelope.status?.kind == .completed)
}

@Test
func kimiStopMapsToWaitingForInputSameAsClaude() throws {
    // Regression: kimi previously had a special carve-out; behavior is now the
    // same as claude's default. Test ensures the kimi path is unchanged.
    let payload = """
    {
      "hook_event_name": "Stop",
      "session_id": "kimi-stop-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .kimi,
        arguments: [
            "island-bridge",
            "--source", "kimi",
            "--client-kind", "kimi"
        ],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Stop")
    #expect(envelope.status?.kind == .waitingForInput)
}

@Test
func unknownStopVariantFallsBackToCompleted() throws {
    // Conservative default: an unknown stop/end-substring event we have not
    // audited stays mapped to .completed so we don't accumulate ghost sessions.
    let payload = """
    {
      "hook_event_name": "MysteryStopThing",
      "session_id": "claude-mystery-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .claude,
        arguments: ["island-bridge", "--source", "claude"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "MysteryStopThing")
    #expect(envelope.status?.kind == .completed)
}
