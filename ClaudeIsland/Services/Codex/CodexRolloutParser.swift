import Foundation

actor CodexRolloutParser {
    static let shared = CodexRolloutParser()

    private struct CachedSnapshot {
        let modificationDate: Date
        let snapshot: CodexThreadSnapshot
    }

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
        var sessionName: String?
        var origin: String?
        var originator: String?
        var threadSource: String?

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
                origin = "desktop"
                originator = stringValue(payload["originator"]) ?? originator
                threadSource = stringValue(payload["source"]) ?? threadSource

            case "turn_context":
                let payload = json["payload"] as? [String: Any] ?? [:]
                latestTurnId = stringValue(payload["turn_id"]) ?? latestTurnId
                resolvedCwd = stringValue(payload["cwd"]) ?? resolvedCwd

            case "event_msg":
                let payload = json["payload"] as? [String: Any] ?? [:]
                switch payload["type"] as? String {
                case "user_message":
                    guard let text = normalizedText(payload["message"]) else { continue }
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
                    phase = .processing

                case "task_complete":
                    if !historyItems.contains(where: Self.isRunningToolItem(_:)) {
                        phase = .idle
                    }

                case "context_compacted":
                    phase = .compacting

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
                    let input = parseJSONStringDictionary(payload["arguments"])
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
                    phase = .processing

                case "custom_tool_call":
                    guard let callId = stringValue(payload["call_id"]),
                          let name = stringValue(payload["name"]) else { continue }
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

        if historyItems.contains(where: Self.isRunningToolItem(_:)) {
            phase = .processing
        } else if phase == .processing, latestFinalText != nil {
            phase = .idle
        }

        let preview = latestFinalText ?? latestAgentText ?? latestUserText ?? firstUserMessage
        let conversationInfo = ConversationInfo(
            summary: sessionName ?? firstUserMessage,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )

        let resolvedClientInfo = SessionClientInfo.codexApp(threadId: resolvedThreadId).merged(with: SessionClientInfo(
            kind: .codexApp,
            name: originator ?? clientInfo?.name,
            bundleIdentifier: clientInfo?.bundleIdentifier ?? "com.openai.codex",
            launchURL: clientInfo?.launchURL ?? SessionClientInfo.appLaunchURL(
                bundleIdentifier: clientInfo?.bundleIdentifier ?? "com.openai.codex",
                sessionId: resolvedThreadId,
                workspacePath: resolvedCwd
            ),
            origin: origin ?? clientInfo?.origin ?? "desktop",
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
            clientInfo: resolvedClientInfo,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? createdAt ?? Date(),
            phase: phase,
            historyItems: historyItems,
            conversationInfo: conversationInfo,
            latestTurnId: latestTurnId,
            latestResponseText: latestFinalText ?? latestAgentText,
            latestResponsePhase: latestFinalPhase ?? latestAgentPhase,
            latestUserText: latestUserText
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

    private static func isRunningToolItem(_ item: ChatHistoryItem) -> Bool {
        guard case .toolCall(let tool) = item.type else {
            return false
        }
        return tool.status == .running || tool.status == .waitingForApproval
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

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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
}

private extension String {
    nonisolated var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
