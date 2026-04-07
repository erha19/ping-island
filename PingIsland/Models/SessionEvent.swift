//
//  SessionEvent.swift
//  PingIsland
//
//  Unified event types for the session state machine.
//  All state changes flow through SessionStore.process(event).
//

import Foundation

/// All events that can affect session state
/// This is the single entry point for state mutations
enum SessionEvent: Sendable {
    // MARK: - Hook Events (from HookSocketServer)

    /// A hook event was received from a hook-based provider
    case hookReceived(HookEvent)

    // MARK: - Permission Events (user actions)

    /// User approved a permission request
    case permissionApproved(sessionId: String, toolUseId: String)

    /// User denied a permission request
    case permissionDenied(sessionId: String, toolUseId: String, reason: String?)

    /// Permission socket failed (connection died before response)
    case permissionSocketFailed(sessionId: String, toolUseId: String)

    /// A question/approval intervention was resolved inside the app
    case interventionResolved(sessionId: String, nextPhase: SessionPhase, submittedAnswers: [String: [String]]?)

    /// Periodic cleanup for stale external-continuation interventions
    case pruneTimedOutExternalContinuations(now: Date)

    // MARK: - File Events (from ConversationParser)

    /// JSONL file was updated with new content
    case fileUpdated(FileUpdatePayload)

    // MARK: - Tool Completion Events (from JSONL parsing)

    /// A tool was detected as completed via JSONL result
    /// This is the authoritative signal that a tool has finished
    case toolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult)

    // MARK: - Interrupt Events (from JSONLInterruptWatcher)

    /// User interrupted Claude (detected via JSONL)
    case interruptDetected(sessionId: String)

    // MARK: - Subagent Events (Task tool tracking)

    /// A Task (subagent) tool has started
    case subagentStarted(sessionId: String, taskToolId: String)

    /// A tool was executed within an active subagent
    case subagentToolExecuted(sessionId: String, tool: SubagentToolCall)

    /// A subagent tool completed (status update)
    case subagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus)

    /// A Task (subagent) tool has stopped
    case subagentStopped(sessionId: String, taskToolId: String)

    /// Agent file was updated with new subagent tools (from AgentFileWatcher)
    case agentFileUpdated(sessionId: String, taskToolId: String, tools: [SubagentToolInfo])

    // MARK: - Clear Events (from JSONL detection)

    /// User issued /clear command - reset UI state while keeping session alive
    case clearDetected(sessionId: String)

    // MARK: - Session Lifecycle

    /// Session has ended
    case sessionEnded(sessionId: String)

    /// User explicitly archived a session from the UI
    case sessionArchived(sessionId: String)

    /// Request to load initial history from file
    case loadHistory(sessionId: String, cwd: String)

    /// History load completed
    case historyLoaded(sessionId: String, messages: [ChatMessage], completedTools: Set<String>, toolResults: [String: ConversationParser.ToolResult], structuredResults: [String: ToolResultData], conversationInfo: ConversationInfo)
}

/// Payload for file update events
struct FileUpdatePayload: Sendable {
    let sessionId: String
    let cwd: String
    /// Messages to process - either only new messages (if isIncremental) or all messages
    let messages: [ChatMessage]
    /// When true, messages contains only NEW messages since last update
    /// When false, messages contains ALL messages (used for initial load or after /clear)
    let isIncremental: Bool
    let completedToolIds: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
}

/// Result of a tool completion detected from JSONL
struct ToolCompletionResult: Sendable {
    let status: ToolStatus
    let result: String?
    let structuredResult: ToolResultData?

    nonisolated static func from(parserResult: ConversationParser.ToolResult?, structuredResult: ToolResultData?) -> ToolCompletionResult {
        let status: ToolStatus
        if parserResult?.isInterrupted == true {
            status = .interrupted
        } else if parserResult?.isError == true {
            status = .error
        } else {
            status = .success
        }

        var resultText: String? = nil
        if let r = parserResult {
            if !r.isInterrupted {
                if let stdout = r.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = r.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = r.content, !content.isEmpty {
                    resultText = content
                }
            }
        }

        return ToolCompletionResult(status: status, result: resultText, structuredResult: structuredResult)
    }
}

// MARK: - Hook Event Extensions

extension HookEvent {
    private nonisolated static let questionToolNames: Set<String> = [
        "askuserquestion",
        "askfollowupquestion"
    ]

    private nonisolated func normalizedJSONValue(_ value: Any) -> Any {
        if let codable = value as? AnyCodable {
            return normalizedJSONValue(codable.value)
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
               let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) {
                return normalizedJSONValue(decoded)
            }
            return string
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { normalizedJSONValue($0) }
        }
        if let dictionary = value as? [String: AnyCodable] {
            return dictionary.mapValues { normalizedJSONValue($0.value) }
        }
        if let array = value as? [Any] {
            return array.map { normalizedJSONValue($0) }
        }
        if let array = value as? [AnyCodable] {
            return array.map { normalizedJSONValue($0.value) }
        }
        return value
    }

    private nonisolated var normalizedToolNameForIntervention: String? {
        guard let tool else { return nil }
        return tool
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private nonisolated var isQoderWorkQuestionEvent: Bool {
        (clientInfo.profileID == "qoderwork" || clientInfo.bundleIdentifier == "com.qoder.work")
            && Self.questionToolNames.contains(normalizedToolNameForIntervention ?? "")
            && !(questionPayloads?.isEmpty ?? true)
    }

    private nonisolated var qoderWorkQuestionInterventionID: String? {
        guard isQoderWorkQuestionEvent else { return nil }
        if let toolUseId, !toolUseId.isEmpty {
            return toolUseId
        }

        let questionID = questionPayloads?
            .compactMap { question in
                (question["id"] as? String)
                    ?? (question["question"] as? String)
                    ?? (question["title"] as? String)
            }
            .joined(separator: "|")

        guard let questionID, !questionID.isEmpty else { return nil }
        return "qoderwork-question-\(sessionId)-\(questionID)"
    }

    nonisolated var isAskUserQuestionRequest: Bool {
        if isQoderWorkQuestionEvent {
            return event == "PreToolUse" || event == "PermissionRequest"
        }

        return event == "PreToolUse"
            && Self.questionToolNames.contains(normalizedToolNameForIntervention ?? "")
            && !(questionPayloads?.isEmpty ?? true)
    }

    nonisolated var questionPayloads: [[String: Any]]? {
        guard let rawQuestions = toolInput?["questions"]?.value else {
            return nil
        }
        let normalizedQuestions = normalizedJSONValue(rawQuestions) as? [[String: Any]]
        guard let normalizedQuestions, !normalizedQuestions.isEmpty else {
            return nil
        }
        return normalizedQuestions
    }

    nonisolated var toolInputJSONObject: [String: Any]? {
        guard let toolInput else { return nil }
        return toolInput.mapValues { normalizedJSONValue($0.value) }
    }

    nonisolated var intervention: SessionIntervention? {
        guard isAskUserQuestionRequest, let questions = questionPayloads else { return nil }
        let actorName = clientInfo.interactionLabel(for: provider)

        let parsedQuestions = questions.enumerated().compactMap { index, question -> SessionInterventionQuestion? in
            let prompt = (question["question"] as? String)
                ?? (question["prompt"] as? String)
                ?? (question["label"] as? String)
            guard let prompt, !prompt.isEmpty else { return nil }

            let options = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { entry -> SessionInterventionOption? in
                let (optionIndex, option) = entry
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return SessionInterventionOption(
                    id: option["id"] as? String ?? "\(index)-option-\(optionIndex)",
                    title: label,
                    detail: option["description"] as? String
                )
            }

            let normalizedOptions: [SessionInterventionOption]
            if !options.isEmpty {
                normalizedOptions = options
            } else if let stringOptions = question["options"] as? [String], !stringOptions.isEmpty {
                normalizedOptions = stringOptions.enumerated().map { optionIndex, label in
                    SessionInterventionOption(
                        id: "\(index)-option-\(optionIndex)",
                        title: label,
                        detail: nil
                    )
                }
            } else {
                normalizedOptions = []
            }

            return SessionInterventionQuestion(
                id: question["id"] as? String ?? prompt,
                header: question["header"] as? String ?? "\(index + 1).",
                prompt: prompt,
                detail: question["description"] as? String,
                options: normalizedOptions,
                allowsMultiple: question["isMultiple"] as? Bool
                    ?? question["allowsMultiple"] as? Bool
                    ?? question["multiSelect"] as? Bool
                    ?? question["multiple"] as? Bool
                    ?? false,
                allowsOther: question["isOther"] as? Bool
                    ?? question["allowsOther"] as? Bool
                    ?? false,
                isSecret: question["isSecret"] as? Bool
                    ?? question["secret"] as? Bool
                    ?? false
            )
        }

        guard !parsedQuestions.isEmpty else { return nil }

        let title = parsedQuestions.count == 1
            ? "\(actorName) 的提问"
            : "\(actorName) 的提问（\(parsedQuestions.count) 个问题）"
        var metadata: [String: String] = ["toolName": "AskUserQuestion"]
        if let toolInputJSONObject,
           let data = try? JSONSerialization.data(withJSONObject: toolInputJSONObject, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            metadata["toolInputJSON"] = json
        }
        // 保存原始 toolUseId，用于后续响应
        if let toolUseId = toolUseId {
            metadata["originalToolUseId"] = toolUseId
        }
        let message: String
        if isQoderWorkQuestionEvent {
            metadata["responseMode"] = "external_only"
            message = "\(actorName) 已在客户端内发起提问，请切回 \(actorName) 完成回答。Island 暂不支持直接提交这类回答。"
        } else {
            message = "\(actorName) 需要你补充回答，提交后会继续执行当前会话。"
        }

        return SessionIntervention(
            id: qoderWorkQuestionInterventionID ?? toolUseId ?? UUID().uuidString,
            kind: .question,
            title: title,
            message: message,
            options: [],
            questions: parsedQuestions,
            supportsSessionScope: false,
            metadata: metadata
        )
    }

    /// Determine the target session phase based on this hook event
    nonisolated func determinePhase() -> SessionPhase {
        // PreCompact takes priority
        if event == "PreCompact" {
            return .compacting
        }

        if isAskUserQuestionRequest {
            return .waitingForInput
        }

        // Permission request creates waitingForApproval state
        if expectsResponse, let tool = tool {
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool,
                toolInput: toolInput,
                receivedAt: Date()
            ))
        }

        if event == "Notification" && notificationType == "idle_prompt" {
            return .idle
        }

        switch status {
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        default:
            return .idle
        }
    }

    /// Whether this is a tool-related event
    nonisolated var isToolEvent: Bool {
        event == "PreToolUse" || event == "PostToolUse" || event == "PermissionRequest"
    }

    /// Whether this event should trigger a file sync
    nonisolated var shouldSyncFile: Bool {
        guard provider == .claude else { return false }

        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop":
            return true
        default:
            return false
        }
    }
}

// MARK: - Debug Description

extension SessionEvent: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .hookReceived(let event):
            return "hookReceived(\(event.event), session: \(event.sessionId.prefix(8)))"
        case .permissionApproved(let sessionId, let toolUseId):
            return "permissionApproved(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionDenied(let sessionId, let toolUseId, _):
            return "permissionDenied(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionSocketFailed(let sessionId, let toolUseId):
            return "permissionSocketFailed(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .interventionResolved(let sessionId, let nextPhase, let submittedAnswers):
            let answerCount = submittedAnswers?.count ?? 0
            return "interventionResolved(session: \(sessionId.prefix(8)), next: \(String(describing: nextPhase)), answers: \(answerCount))"
        case .pruneTimedOutExternalContinuations(let now):
            return "pruneTimedOutExternalContinuations(now: \(now))"
        case .fileUpdated(let payload):
            return "fileUpdated(session: \(payload.sessionId.prefix(8)), messages: \(payload.messages.count))"
        case .interruptDetected(let sessionId):
            return "interruptDetected(session: \(sessionId.prefix(8)))"
        case .clearDetected(let sessionId):
            return "clearDetected(session: \(sessionId.prefix(8)))"
        case .sessionEnded(let sessionId):
            return "sessionEnded(session: \(sessionId.prefix(8)))"
        case .sessionArchived(let sessionId):
            return "sessionArchived(session: \(sessionId.prefix(8)))"
        case .loadHistory(let sessionId, _):
            return "loadHistory(session: \(sessionId.prefix(8)))"
        case .historyLoaded(let sessionId, let messages, _, _, _, _):
            return "historyLoaded(session: \(sessionId.prefix(8)), messages: \(messages.count))"
        case .toolCompleted(let sessionId, let toolUseId, let result):
            return "toolCompleted(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)), status: \(result.status))"
        case .subagentStarted(let sessionId, let taskToolId):
            return "subagentStarted(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .subagentToolExecuted(let sessionId, let tool):
            return "subagentToolExecuted(session: \(sessionId.prefix(8)), tool: \(tool.name))"
        case .subagentToolCompleted(let sessionId, let toolId, let status):
            return "subagentToolCompleted(session: \(sessionId.prefix(8)), tool: \(toolId.prefix(12)), status: \(status))"
        case .subagentStopped(let sessionId, let taskToolId):
            return "subagentStopped(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .agentFileUpdated(let sessionId, let taskToolId, let tools):
            return "agentFileUpdated(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)), tools: \(tools.count))"
        }
    }
}
