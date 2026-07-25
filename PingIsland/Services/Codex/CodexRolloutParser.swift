import Foundation

actor CodexRolloutParser {
    static let shared = CodexRolloutParser()

    private struct ParsedSubagentMetadata {
        let parentThreadId: String?
        let depth: Int?
        let nickname: String?
        let role: String?
    }

    private struct CachedSnapshot {
        let modificationDate: Date
        let snapshot: CodexThreadSnapshot
    }

    private let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let wholeSecondTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var cache: [String: CachedSnapshot] = [:]

    func parseThread(
        threadId: String,
        fallbackCwd: String,
        clientInfo: SessionClientInfo?
    ) -> CodexThreadSnapshot? {
        guard let fileURL = resolveRolloutURL(threadId: threadId, clientInfo: clientInfo),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }

        if let cached = cache[fileURL.path], cached.modificationDate == modificationDate {
            return cached.snapshot
        }

        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let snapshot = parseRollout(
            raw,
            fileURL: fileURL,
            fallbackThreadId: threadId,
            fallbackCwd: fallbackCwd,
            clientInfo: clientInfo
        )

        if let snapshot {
            cache[fileURL.path] = CachedSnapshot(
                modificationDate: modificationDate,
                snapshot: snapshot
            )
        }

        return snapshot
    }

    private func parseRollout(
        _ content: String,
        fileURL: URL,
        fallbackThreadId: String,
        fallbackCwd: String,
        clientInfo: SessionClientInfo?
    ) -> CodexThreadSnapshot? {
        let lines = content.split(separator: "\n")
        guard !lines.isEmpty else { return nil }

        var resolvedThreadId = fallbackThreadId
        var resolvedCwd = fallbackCwd.nonEmpty ?? "/"
        var createdAt: Date?
        var updatedAt: Date?
        var latestTurnId: String?

        var historyItems: [ChatHistoryItem] = []
        var toolIndexes: [String: Int] = [:]
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessageDate: Date?
        var latestUserText: String?
        var latestAgentText: String?
        var latestAgentPhase: String?
        var latestFinalText: String?
        var latestFinalPhase: String?
        var phase: SessionPhase = .idle
        var hasOpenTask = false
        var isTurnInterrupted = false
        var intervention: SessionIntervention?
        var sessionName: String?
        var origin: String?
        var originator: String?
        var threadSource: String?
        var subagentMetadata = ParsedSubagentMetadata(
            parentThreadId: nil,
            depth: nil,
            nickname: nil,
            role: nil
        )

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let timestamp = parseISO8601(json["timestamp"] as? String) ?? Date()
            createdAt = createdAt ?? timestamp
            updatedAt = timestamp

            switch json["type"] as? String {
            case "session_meta":
                let payload = json["payload"] as? [String: Any] ?? [:]
                resolvedThreadId = stringValue(payload["id"]) ?? resolvedThreadId
                resolvedCwd = stringValue(payload["cwd"]) ?? resolvedCwd
                sessionName = stringValue(payload["title"]) ?? sessionName
                let sourceValue = payload["source"]
                let source = stringValue(sourceValue)
                origin = stringValue(payload["origin"]) ?? (source == "cli" ? "cli" : origin)
                originator = stringValue(payload["originator"]) ?? originator
                threadSource = source ?? threadSource
                if let parsedSubagentMetadata = parseSubagentMetadata(
                    payload: payload,
                    sourceValue: sourceValue
                ) {
                    subagentMetadata = parsedSubagentMetadata
                    threadSource = threadSource ?? "subagent"
                }

            case "turn_context":
                let payload = json["payload"] as? [String: Any] ?? [:]
                latestTurnId = stringValue(payload["turn_id"]) ?? latestTurnId
                resolvedCwd = stringValue(payload["cwd"]) ?? resolvedCwd

            case "event_msg":
                let payload = json["payload"] as? [String: Any] ?? [:]
                switch payload["type"] as? String {
                case "user_message":
                    guard let text = normalizedText(payload["message"]) else { continue }
                    isTurnInterrupted = false
                    if firstUserMessage == nil {
                        firstUserMessage = text
                    }
                    latestUserText = text
                    lastMessage = text
                    lastMessageRole = "user"
                    lastUserMessageDate = timestamp
                    historyItems.append(ChatHistoryItem(
                        id: "codex-user-\(index)",
                        type: .user(text),
                        timestamp: timestamp
                    ))
                    phase = .processing

                case "agent_message":
                    guard let text = normalizedText(payload["message"]) else { continue }
                    let messagePhase = stringValue(payload["phase"]) ?? "assistant"
                    latestAgentText = text
                    latestAgentPhase = messagePhase
                    lastMessage = text
                    lastMessageRole = "assistant"

                    let itemType: ChatHistoryItemType
                    if messagePhase == "commentary" {
                        itemType = .thinking(text)
                    } else {
                        itemType = .assistant(text)
                        latestFinalText = text
                        latestFinalPhase = messagePhase
                    }

                    historyItems.append(ChatHistoryItem(
                        id: "codex-agent-\(index)",
                        type: itemType,
                        timestamp: timestamp
                    ))

                case "task_started":
                    isTurnInterrupted = false
                    hasOpenTask = true
                    phase = .processing

                case "task_complete":
                    hasOpenTask = false
                    if !historyItems.contains(where: Self.isRunningToolItem(_:)) {
                        phase = .idle
                    }

                case "context_compacted":
                    phase = .compacting

                case "turn_aborted":
                    isTurnInterrupted = true
                    hasOpenTask = false
                    intervention = nil
                    markRunningToolsInterrupted(in: &historyItems)
                    phase = .idle

                default:
                    continue
                }

            case "response_item":
                let payload = json["payload"] as? [String: Any] ?? [:]
                let payloadType = payload["type"] as? String

                switch payloadType {
                case "function_call":
                    guard let callId = stringValue(payload["call_id"]),
                          let name = stringValue(payload["name"]) else { continue }
                    isTurnInterrupted = false
                    let inputObject = parseJSONStringObject(payload["arguments"])
                    let input = parseJSONStringDictionary(inputObject ?? payload["arguments"])
                    let item = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(ToolCallItem(
                            name: name,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: timestamp
                    )
                    toolIndexes[callId] = historyItems.count
                    historyItems.append(item)
                    if let questionIntervention = codexUserInputIntervention(
                        callId: callId,
                        toolName: name,
                        input: inputObject
                    ) {
                        intervention = questionIntervention
                        phase = .waitingForInput
                    } else {
                        phase = .processing
                    }

                case "custom_tool_call":
                    guard let callId = stringValue(payload["call_id"]),
                          let name = stringValue(payload["name"]) else { continue }
                    isTurnInterrupted = false
                    let input = customToolInput(from: payload["input"])
                    let status = stringValue(payload["status"]) == "completed" ? ToolStatus.success : .running
                    let item = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(ToolCallItem(
                            name: name,
                            input: input,
                            status: status,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: timestamp
                    )
                    toolIndexes[callId] = historyItems.count
                    historyItems.append(item)
                    if status == .running {
                        phase = .processing
                    }

                case "web_search_call":
                    guard let callId = stringValue(payload["call_id"]) else { continue }
                    isTurnInterrupted = false
                    let query = stringValue(payload["query"]) ?? stringValue(payload["input"]) ?? ""
                    let item = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(ToolCallItem(
                            name: "web_search",
                            input: query.isEmpty ? [:] : ["query": query],
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: timestamp
                    )
                    toolIndexes[callId] = historyItems.count
                    historyItems.append(item)
                    phase = .processing

                case "function_call_output":
                    guard let callId = stringValue(payload["call_id"]),
                          let toolIndex = toolIndexes[callId],
                          case .toolCall(var tool) = historyItems[toolIndex].type else { continue }
                    let output = normalizedText(payload["output"])
                    tool.status = inferredToolStatus(fromOutput: output) ?? .success
                    tool.result = output
                    historyItems[toolIndex] = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(tool),
                        timestamp: historyItems[toolIndex].timestamp
                    )
                    if intervention?.matchesResolvedToolUseId(callId) == true {
                        intervention = nil
                        phase = .processing
                    }

                case "custom_tool_call_output":
                    guard let callId = stringValue(payload["call_id"]),
                          let toolIndex = toolIndexes[callId],
                          case .toolCall(var tool) = historyItems[toolIndex].type else { continue }
                    let nested = parseJSONStringObject(payload["output"])
                    let output = normalizedText(nested?["output"] ?? payload["output"])
                    let exitCode = nested?["metadata"].flatMap { metadata -> Int? in
                        guard let metadata = metadata as? [String: Any] else { return nil }
                        return intValue(metadata["exit_code"])
                    }
                    tool.status = (exitCode == nil || exitCode == 0) ? .success : .error
                    tool.result = output
                    historyItems[toolIndex] = ChatHistoryItem(
                        id: callId,
                        type: .toolCall(tool),
                        timestamp: historyItems[toolIndex].timestamp
                    )

                default:
                    continue
                }

            default:
                continue
            }
        }

        if intervention?.kind == .question {
            phase = .waitingForInput
        } else if isTurnInterrupted {
            markRunningToolsInterrupted(in: &historyItems)
            phase = .idle
        } else if historyItems.contains(where: Self.isRunningToolItem(_:)) {
            phase = .processing
        } else if hasOpenTask {
            // Mid-turn assistant/commentary text must not demote an open Desktop turn
            // to idle — primary UI now hides idle Codex rows.
            phase = .processing
        } else if phase == .processing, latestFinalText != nil {
            phase = .idle
        }

        let preview = latestFinalText ?? latestAgentText ?? latestUserText ?? firstUserMessage
        guard !CodexAuxiliaryHookFilter.isCodexMemoryMaintenanceThread(
            cwd: resolvedCwd,
            title: sessionName,
            preview: preview
        ) else {
            return nil
        }

        let conversationInfo = ConversationInfo(
            summary: sessionName ?? firstUserMessage,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )

        let prefersCLIContext = clientInfo?.kind == .codexCLI
            || origin == "cli"
            || threadSource == "cli"
            || (clientInfo?.terminalBundleIdentifier?.isEmpty == false
                && clientInfo?.terminalBundleIdentifier != "com.openai.codex")
            || clientInfo?.terminalSessionIdentifier?.isEmpty == false
            || clientInfo?.iTermSessionIdentifier?.isEmpty == false

        if prefersCLIContext,
           let inferredIntervention = Self.pendingMCPApprovalIntervention(from: historyItems) {
            intervention = inferredIntervention
            phase = .waitingForInput
        }

        let baseClientInfo = prefersCLIContext
            ? SessionClientInfo.codexCLI()
            : SessionClientInfo.codexApp(threadId: resolvedThreadId)

        let resolvedClientInfo = baseClientInfo.merged(with: SessionClientInfo(
            kind: prefersCLIContext ? .codexCLI : .codexApp,
            name: originator ?? clientInfo?.name,
            bundleIdentifier: prefersCLIContext ? clientInfo?.bundleIdentifier : (clientInfo?.bundleIdentifier ?? "com.openai.codex"),
            launchURL: prefersCLIContext
                ? clientInfo?.launchURL
                : (clientInfo?.launchURL ?? SessionClientInfo.appLaunchURL(
                    bundleIdentifier: clientInfo?.bundleIdentifier ?? "com.openai.codex",
                    sessionId: resolvedThreadId,
                    workspacePath: resolvedCwd
                )),
            origin: origin ?? clientInfo?.origin ?? (prefersCLIContext ? "cli" : "desktop"),
            originator: originator ?? clientInfo?.originator,
            threadSource: threadSource ?? clientInfo?.threadSource,
            transport: clientInfo?.transport,
            remoteHost: clientInfo?.remoteHost,
            sessionFilePath: fileURL.path,
            terminalBundleIdentifier: clientInfo?.terminalBundleIdentifier,
            terminalProgram: clientInfo?.terminalProgram,
            terminalSessionIdentifier: clientInfo?.terminalSessionIdentifier,
            iTermSessionIdentifier: clientInfo?.iTermSessionIdentifier,
            tmuxSessionIdentifier: clientInfo?.tmuxSessionIdentifier,
            tmuxPaneIdentifier: clientInfo?.tmuxPaneIdentifier,
            processName: clientInfo?.processName
        ))

        return CodexThreadSnapshot(
            threadId: resolvedThreadId,
            name: sessionName,
            preview: preview,
            cwd: resolvedCwd,
            parentThreadId: subagentMetadata.parentThreadId,
            subagentDepth: subagentMetadata.depth,
            subagentNickname: subagentMetadata.nickname,
            subagentRole: subagentMetadata.role,
            clientInfo: resolvedClientInfo,
            intervention: intervention,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? createdAt ?? Date(),
            phase: phase,
            historyItems: historyItems,
            conversationInfo: conversationInfo,
            latestTurnId: latestTurnId,
            latestResponseText: latestFinalText ?? latestAgentText,
            latestResponsePhase: latestFinalPhase ?? latestAgentPhase,
            latestUserText: latestUserText,
            isTurnInterrupted: isTurnInterrupted
        )
    }

    private func resolveRolloutURL(threadId: String, clientInfo: SessionClientInfo?) -> URL? {
        if let sessionFilePath = clientInfo?.sessionFilePath?.nonEmpty,
           FileManager.default.fileExists(atPath: sessionFilePath) {
            return URL(fileURLWithPath: sessionFilePath)
        }

        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        let suffix = "-\(threadId).jsonl"
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.hasSuffix(suffix) else {
                continue
            }
            return fileURL
        }

        return nil
    }

    private func parseSubagentMetadata(
        payload: [String: Any],
        sourceValue: Any?
    ) -> ParsedSubagentMetadata? {
        let topLevelNickname = stringValue(payload["agent_nickname"])
        let topLevelRole = stringValue(payload["agent_role"])
        let forkedFromId = stringValue(payload["forked_from_id"])

        guard let sourceObject = sourceValue as? [String: Any] else {
            if forkedFromId == nil, topLevelNickname == nil, topLevelRole == nil {
                return nil
            }

            return ParsedSubagentMetadata(
                parentThreadId: forkedFromId,
                depth: nil,
                nickname: topLevelNickname,
                role: topLevelRole
            )
        }

        let subagent = sourceObject["subagent"] as? [String: Any]
        let threadSpawn = subagent?["thread_spawn"] as? [String: Any]

        let parentThreadId = stringValue(threadSpawn?["parent_thread_id"]) ?? forkedFromId
        let depth = intValue(threadSpawn?["depth"])
        let nickname = stringValue(threadSpawn?["agent_nickname"]) ?? topLevelNickname
        let role = stringValue(threadSpawn?["agent_role"]) ?? topLevelRole

        guard parentThreadId != nil || depth != nil || nickname != nil || role != nil else {
            return nil
        }

        return ParsedSubagentMetadata(
            parentThreadId: parentThreadId,
            depth: depth,
            nickname: nickname,
            role: role
        )
    }

    private static func isRunningToolItem(_ item: ChatHistoryItem) -> Bool {
        guard case .toolCall(let tool) = item.type else {
            return false
        }
        return tool.status == .running || tool.status == .waitingForApproval
    }

    private func markRunningToolsInterrupted(in historyItems: inout [ChatHistoryItem]) {
        for index in historyItems.indices {
            guard case .toolCall(var tool) = historyItems[index].type,
                  tool.status == .running || tool.status == .waitingForApproval else {
                continue
            }

            tool.status = .interrupted
            historyItems[index] = ChatHistoryItem(
                id: historyItems[index].id,
                type: .toolCall(tool),
                timestamp: historyItems[index].timestamp
            )
        }
    }

    private static func pendingMCPApprovalIntervention(from historyItems: [ChatHistoryItem]) -> SessionIntervention? {
        for item in historyItems.reversed() {
            guard case .toolCall(let tool) = item.type,
                  tool.status == .running,
                  tool.name.hasPrefix("mcp__") else {
                continue
            }

            let parts = tool.name.split(separator: "__", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let server = String(parts[1])
            let toolName = parts[2...].joined(separator: "__")

            return SessionIntervention(
                id: "mcp-pending-\(server)-\(toolName)",
                kind: .question,
                title: "MCP Tool Approval Needed",
                message: "Allow the \(server) MCP server to run tool \"\(toolName)\"?",
                options: [],
                questions: [],
                supportsSessionScope: false,
                metadata: [
                    "responseMode": "external_only",
                    "source": "rollout_pending_mcp",
                    "server": server,
                    "toolName": toolName
                ]
            )
        }

        return nil
    }

    private func codexUserInputIntervention(
        callId: String,
        toolName: String,
        input: [String: Any]?
    ) -> SessionIntervention? {
        guard normalizedToolName(toolName) == "requestuserinput" else {
            return nil
        }

        let questions = parseInterventionQuestions(input?["questions"] as? [[String: Any]] ?? [])
        guard !questions.isEmpty else {
            return nil
        }

        let prompt = questions.first?.prompt ?? "Codex needs your input."
        var metadata: [String: String] = [
            "source": "codex_rollout_request_user_input",
            "responseMode": "external_only",
            "toolName": toolName,
            "toolUseId": callId
        ]
        if let input,
           JSONSerialization.isValidJSONObject(input),
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            metadata["toolInputJSON"] = json
        }

        return SessionIntervention(
            id: callId,
            kind: .question,
            title: "Codex Needs Input",
            message: prompt,
            options: questions.first?.options ?? [],
            questions: questions,
            supportsSessionScope: false,
            metadata: metadata
        )
    }

    private func parseInterventionQuestions(_ rawQuestions: [[String: Any]]) -> [SessionInterventionQuestion] {
        rawQuestions.enumerated().compactMap { index, question in
            let prompt = stringValue(question["question"])
                ?? stringValue(question["prompt"])
                ?? stringValue(question["label"])
            guard let prompt, !prompt.isEmpty else { return nil }

            let objectOptions = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { optionIndex, option -> SessionInterventionOption? in
                guard let label = stringValue(option["label"]) ?? stringValue(option["title"]),
                      !label.isEmpty else { return nil }
                return SessionInterventionOption(
                    id: stringValue(option["id"]) ?? label,
                    title: label,
                    detail: stringValue(option["description"])
                )
            }

            let stringOptions = (question["options"] as? [String] ?? []).enumerated().map { optionIndex, label in
                SessionInterventionOption(
                    id: "\(index)-option-\(optionIndex)",
                    title: label,
                    detail: nil
                )
            }

            return SessionInterventionQuestion(
                id: stringValue(question["id"]) ?? prompt,
                header: stringValue(question["header"]) ?? "\(index + 1).",
                prompt: prompt,
                detail: stringValue(question["description"]),
                options: objectOptions.isEmpty ? stringOptions : objectOptions,
                allowsMultiple: boolValue(question["isMultiple"])
                    ?? boolValue(question["allowsMultiple"])
                    ?? boolValue(question["multiSelect"])
                    ?? boolValue(question["multiple"])
                    ?? false,
                allowsOther: true,
                isSecret: boolValue(question["isSecret"])
                    ?? boolValue(question["secret"])
                    ?? false
            )
        }
    }

    private func parseJSONStringDictionary(_ value: Any?) -> [String: String] {
        guard let object = parseJSONStringObject(value) else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, raw) in object {
            if let string = stringValue(raw) {
                result[key] = string
            } else if JSONSerialization.isValidJSONObject(raw),
                      let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
                      let string = String(data: data, encoding: .utf8) {
                result[key] = string
            }
        }
        return result
    }

    private func parseJSONStringObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func customToolInput(from value: Any?) -> [String: String] {
        if let dictionary = parseJSONStringObject(value), !dictionary.isEmpty {
            return parseJSONStringDictionary(dictionary)
        }
        if let string = stringValue(value) {
            return ["input": string]
        }
        return [:]
    }

    private func inferredToolStatus(fromOutput output: String?) -> ToolStatus? {
        guard let output else { return nil }

        if let range = output.range(of: "Process exited with code ") {
            let suffix = output[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let code = Int(digits) {
                return code == 0 ? .success : .error
            }
        }

        return nil
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value = value?.nonEmpty else { return nil }

        if let date = fractionalTimestampFormatter.date(from: value) {
            return date
        }

        return wholeSecondTimestampFormatter.date(from: value)
    }

    private func normalizedText(_ value: Any?) -> String? {
        stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(normalized) {
                return true
            }
            if ["false", "no", "0"].contains(normalized) {
                return false
            }
            return nil
        default:
            return nil
        }
    }

    private func normalizedToolName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
