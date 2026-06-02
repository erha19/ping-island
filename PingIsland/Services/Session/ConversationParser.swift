//
//  ConversationParser.swift
//  PingIsland
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

struct ConversationInfo: Equatable, Sendable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user", "assistant", or "tool"
    let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String?  // Fallback title when no summary
    let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
}

actor ConversationParser {
    static let shared = ConversationParser()

    struct QoderSubagentPresentation: Equatable, Sendable {
        let displayTitle: String
    }

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Parser")

    /// Cache of parsed conversation info, keyed by session file path
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]

    private struct CachedInfo {
        let modificationDate: Date
        let info: ConversationInfo
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]  // Map tool_use_id to tool name
        var completedToolIds: Set<String> = []  // Tools that have received results
        var toolResults: [String: ToolResult] = [:]  // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:]  // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0  // Offset of last /clear command (0 = none or at start)
        var clearPending: Bool = false  // True if a /clear was just detected
    }

    private enum TranscriptFormat {
        case claudeLike
        case openClaw
        case codeBuddyHistory
    }

    private nonisolated static let codeBuddyQuestionToolNames: Set<String> = [
        "askuserquestion",
        "askfollowupquestion"
    ]

    /// Parsed tool result data
    struct ToolResult {
        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                content?.contains("interrupted by user") == true ||
                content?.contains("user doesn't want to proceed") == true
            )
        }
    }

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    func parse(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> ConversationInfo {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        let transcriptFormat = Self.transcriptFormat(for: sessionFile)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        if let cached = cache[sessionFile], cached.modificationDate == modDate {
            return cached.info
        }

        guard let data = fileManager.contents(atPath: sessionFile),
              let content = String(data: data, encoding: .utf8) else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        let info = switch transcriptFormat {
        case .claudeLike:
            parseContent(content)
        case .openClaw:
            parseOpenClawContent(content)
        case .codeBuddyHistory:
            parseCodeBuddyHistory(filePath: sessionFile)
        }
        cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)

        return info
    }

    /// Parse JSONL content
    private func parseContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false

            if type == "user" && !isMeta {
                if let message = json["message"] as? [String: Any],
                   let msgContent = Self.firstDisplayText(in: message) {
                    firstUserMessage = Self.truncateMessage(msgContent, maxLength: 50)
                    break
                }
            }
        }

        var foundLastUserMessage = false
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String

            if lastMessage == nil {
                if type == "user" || type == "assistant" {
                    let isMeta = json["isMeta"] as? Bool ?? false
                    if !isMeta, let message = json["message"] as? [String: Any] {
                        for block in Self.contentBlocks(in: message).reversed() {
                            let blockType = block["type"] as? String
                            if blockType == "tool_use" {
                                let toolName = block["name"] as? String ?? "Tool"
                                let toolInput = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                lastMessage = toolInput
                                lastMessageRole = "tool"
                                lastToolName = toolName
                                break
                            } else if blockType == "text",
                                      let text = block["text"] as? String,
                                      let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text),
                                      Self.isDisplayableText(sanitizedText),
                                      !sanitizedText.hasPrefix("[Request interrupted by user") {
                                lastMessage = sanitizedText
                                lastMessageRole = type
                                break
                            }
                        }
                    }
                }
            }

            if !foundLastUserMessage && type == "user" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if Self.firstDisplayText(in: message) != nil {
                        if let timestampStr = json["timestamp"] as? String {
                            lastUserMessageDate = formatter.date(from: timestampStr)
                        }
                        foundLastUserMessage = true
                    }
                }
            }

            if summary == nil, type == "summary", let summaryText = json["summary"] as? String {
                summary = summaryText
            }

            if summary != nil && lastMessage != nil && foundLastUserMessage {
                break
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    private static func contentBlocks(in message: [String: Any]) -> [[String: Any]] {
        if let text = message["content"] as? String {
            return [["type": "text", "text": text]]
        }

        if let contentArray = message["content"] as? [[String: Any]] {
            return contentArray
        }

        return []
    }

    private static func firstDisplayText(in message: [String: Any]) -> String? {
        for block in contentBlocks(in: message) {
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text),
                  isDisplayableText(sanitizedText) else {
                continue
            }
            return sanitizedText
        }

        return nil
    }

    private static func isDisplayableText(_ text: String) -> Bool {
        !text.hasPrefix("<command-name>")
            && !text.hasPrefix("<local-command")
            && !text.hasPrefix("Caveat:")
    }

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task":
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    /// Truncate message for display
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> [ChatMessage] {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        let transcriptFormat = Self.transcriptFormat(for: sessionFile)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return []
        }

        if transcriptFormat == .codeBuddyHistory {
            let snapshot = parseCodeBuddyHistorySnapshot(filePath: sessionFile)
            var state = incrementalState[sessionId] ?? IncrementalParseState()
            state.messages = snapshot.messages
            state.completedToolIds = snapshot.completedToolIds
            state.toolResults = snapshot.toolResults
            state.structuredResults = snapshot.structuredResults
            incrementalState[sessionId] = state
            return snapshot.messages
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        _ = parseNewLines(filePath: sessionFile, state: &state, transcriptFormat: transcriptFormat)
        incrementalState[sessionId] = state

        return state.messages
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> IncrementalParseResult {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        let transcriptFormat = Self.transcriptFormat(for: sessionFile)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        if transcriptFormat == .codeBuddyHistory {
            var state = incrementalState[sessionId] ?? IncrementalParseState()
            let existingMessageIDs = Set(state.messages.map(\.id))
            let snapshot = parseCodeBuddyHistorySnapshot(filePath: sessionFile)
            let newMessages = snapshot.messages.filter { !existingMessageIDs.contains($0.id) }
            state.messages = snapshot.messages
            state.completedToolIds = snapshot.completedToolIds
            state.toolResults = snapshot.toolResults
            state.structuredResults = snapshot.structuredResults
            incrementalState[sessionId] = state

            return IncrementalParseResult(
                newMessages: newMessages,
                allMessages: snapshot.messages,
                completedToolIds: snapshot.completedToolIds,
                toolResults: snapshot.toolResults,
                structuredResults: snapshot.structuredResults,
                clearDetected: false
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let newMessages = parseNewLines(filePath: sessionFile, state: &state, transcriptFormat: transcriptFormat)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionId] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected
        )
    }

    /// Parse only new lines since last read (incremental)
    private func parseNewLines(
        filePath: String,
        state: inout IncrementalParseState,
        transcriptFormat: TranscriptFormat
    ) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return state.messages
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return state.messages
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return state.messages
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []

        if transcriptFormat == .openClaw {
            for line in lines where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let message = parseOpenClawMessageLine(json) else {
                    continue
                }
                newMessages.append(message)
                state.messages.append(message)
            }

            state.lastFileOffset = fileSize
            return newMessages
        }

        for line in lines where !line.isEmpty {
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if line.contains("\"tool_result\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseId = block["tool_use_id"] as? String {
                            state.completedToolIds.insert(toolUseId)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseId] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError
                            )

                            let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]

                            if let toolUseResult = toolUseResult,
                               let name = toolName {
                                let structured = Self.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError
                                )
                                state.structuredResults[toolUseId] = structured
                            }
                        }
                    }
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, toolIdToName: &state.toolIdToName) {
                    newMessages.append(message)
                    state.messages.append(message)
                }
            }
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    /// Get set of completed tool IDs for a session
    func completedToolIds(for sessionId: String) -> Set<String> {
        return incrementalState[sessionId]?.completedToolIds ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionId: String) -> [String: ToolResult] {
        return incrementalState[sessionId]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        return incrementalState[sessionId]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionId: String) -> Bool {
        guard var state = incrementalState[sessionId], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionId] = state
        return true
    }

    /// Build session file path
    private static func sessionFilePath(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> String {
        if let explicitFilePath, !explicitFilePath.isEmpty {
            if FileManager.default.fileExists(atPath: explicitFilePath) {
                return explicitFilePath
            }

            if let fallbackOpenClawPath = latestOpenClawSessionFilePath(preferredPath: explicitFilePath) {
                return fallbackOpenClawPath
            }

            return explicitFilePath
        }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let qoderPath = NSHomeDirectory() + "/.qoder/projects/" + projectDir + "/transcript/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderPath) {
            return qoderPath
        }

        let qoderWorkPath = NSHomeDirectory() + "/.qoderwork/projects/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderWorkPath) {
            return qoderWorkPath
        }

        let claudePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: claudePath) {
            return claudePath
        }

        if let fallbackOpenClawPath = latestOpenClawSessionFilePath(preferredPath: nil) {
            return fallbackOpenClawPath
        }

        return claudePath
    }

    private static func latestOpenClawSessionFilePath(preferredPath: String?) -> String? {
        let fileManager = FileManager.default
        let sessionsDirectory: URL = {
            if let preferredPath {
                return URL(fileURLWithPath: preferredPath).deletingLastPathComponent()
            }
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw/agents/main/sessions", isDirectory: true)
        }()

        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newestURL: URL?
        var newestDate = Date.distantPast

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modifiedAt = values?.contentModificationDate ?? Date.distantPast
            if newestURL == nil || modifiedAt > newestDate {
                newestURL = fileURL
                newestDate = modifiedAt
            }
        }

        return newestURL?.path
    }

    private static func transcriptFormat(for filePath: String) -> TranscriptFormat {
        if filePath.contains("/.openclaw/agents/") {
            return .openClaw
        }

        if filePath.hasSuffix("/index.json") || URL(fileURLWithPath: filePath).lastPathComponent == "index.json" {
            return .codeBuddyHistory
        }

        return .claudeLike
    }

    private func parseOpenClawContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessageDate: Date?

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = parseOpenClawMessageLine(json) else {
                continue
            }

            if firstUserMessage == nil, message.role == .user {
                firstUserMessage = Self.truncateMessage(message.textContent, maxLength: 50)
            }

            let text = message.textContent
            guard !text.isEmpty else { continue }
            lastMessage = text
            lastMessageRole = message.role.rawValue
            if message.role == .user {
                lastUserMessageDate = message.timestamp
            }
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    private struct CodeBuddyHistorySnapshot {
        let messages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
    }

    private func parseCodeBuddyHistory(filePath: String) -> ConversationInfo {
        let snapshot = parseCodeBuddyHistorySnapshot(filePath: filePath)

        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var lastUserMessageDate: Date?

        for message in snapshot.messages {
            if firstUserMessage == nil,
               message.role == .user,
               !message.textContent.isEmpty {
                firstUserMessage = Self.truncateMessage(message.textContent, maxLength: 50)
            }

            if message.role == .user, !message.textContent.isEmpty {
                lastUserMessageDate = message.timestamp
            }
        }

        for message in snapshot.messages.reversed() {
            if let toolBlock = message.content.reversed().compactMap({ block -> ToolUseBlock? in
                guard case .toolUse(let tool) = block else { return nil }
                return tool
            }).first {
                lastMessage = toolBlock.preview
                lastMessageRole = "tool"
                lastToolName = toolBlock.name
                break
            }

            let text = Self.truncateMessage(message.textContent, maxLength: 80)
            guard let text, !text.isEmpty else { continue }
            lastMessage = text
            lastMessageRole = message.role.rawValue
            break
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    private func parseCodeBuddyHistorySnapshot(filePath: String) -> CodeBuddyHistorySnapshot {
        guard
            let data = FileManager.default.contents(atPath: filePath),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return CodeBuddyHistorySnapshot(
                messages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:]
            )
        }

        let messageEntries = json["messages"] as? [[String: Any]] ?? []
        let requests = json["requests"] as? [[String: Any]] ?? []
        let messagesDirectoryURL = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("messages", isDirectory: true)

        var timestampByMessageID: [String: Date] = [:]
        for request in requests {
            let messageIDs = request["messages"] as? [String] ?? []
            let baseTimestamp = codeBuddyHistoryTimestamp(from: request["startedAt"])
            for (index, messageID) in messageIDs.enumerated() {
                if let baseTimestamp {
                    timestampByMessageID[messageID] = baseTimestamp.addingTimeInterval(TimeInterval(index) * 0.001)
                }
            }
        }

        var seenToolIDs: Set<String> = []
        var toolIDToName: [String: String] = [:]
        var completedToolIDs: Set<String> = []
        var toolResults: [String: ToolResult] = [:]
        var structuredResults: [String: ToolResultData] = [:]
        var messages: [ChatMessage] = []

        for entry in messageEntries {
            guard
                let messageID = entry["id"] as? String,
                let role = entry["role"] as? String
            else {
                continue
            }

            let messageURL = messagesDirectoryURL.appendingPathComponent("\(messageID).json", isDirectory: false)
            guard
                let messageData = FileManager.default.contents(atPath: messageURL.path),
                let messageJSON = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any]
            else {
                continue
            }

            let timestamp = timestampByMessageID[messageID]
                ?? codeBuddyHistoryTimestamp(from: messageJSON["createdAt"])
                ?? codeBuddyHistoryTimestamp(from: messageJSON["updatedAt"])
                ?? ((try? messageURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                ?? Date()

            if role == "tool" {
                parseCodeBuddyHistoryToolMessage(
                    messageJSON,
                    completedToolIDs: &completedToolIDs,
                    toolResults: &toolResults,
                    structuredResults: &structuredResults,
                    toolIDToName: &toolIDToName
                )
                continue
            }

            guard let chatMessage = parseCodeBuddyHistoryMessage(
                messageID: messageID,
                role: role,
                timestamp: timestamp,
                messageJSON: messageJSON,
                seenToolIDs: &seenToolIDs,
                toolIDToName: &toolIDToName
            ) else {
                continue
            }

            messages.append(chatMessage)
        }

        return CodeBuddyHistorySnapshot(
            messages: messages,
            completedToolIds: completedToolIDs,
            toolResults: toolResults,
            structuredResults: structuredResults
        )
    }

    private func parseCodeBuddyHistoryMessage(
        messageID: String,
        role: String,
        timestamp: Date,
        messageJSON: [String: Any],
        seenToolIDs: inout Set<String>,
        toolIDToName: inout [String: String]
    ) -> ChatMessage? {
        let chatRole: ChatRole
        switch role {
        case "user":
            chatRole = .user
        case "assistant":
            chatRole = .assistant
        default:
            return nil
        }

        guard let messageDict = Self.codeBuddyHistoryMessagePayload(from: messageJSON["message"]) else {
            return nil
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if let sanitizedContent = sanitizedCodeBuddyHistoryText(content), !sanitizedContent.isEmpty {
                blocks.append(.text(sanitizedContent))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "text":
                    if let text = block["text"] as? String,
                       let sanitizedText = sanitizedCodeBuddyHistoryText(text),
                       !sanitizedText.isEmpty {
                        blocks.append(.text(sanitizedText))
                    }
                case "reasoning", "thinking":
                    if let text = (block["text"] as? String) ?? (block["thinking"] as? String),
                       let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text),
                       !sanitizedText.isEmpty {
                        blocks.append(.thinking(sanitizedText))
                    }
                case "tool-call":
                    guard
                        let toolID = (block["toolCallId"] as? String) ?? (block["id"] as? String),
                        let toolName = (block["toolName"] as? String) ?? (block["name"] as? String),
                        seenToolIDs.insert(toolID).inserted
                    else {
                        continue
                    }
                    toolIDToName[toolID] = toolName
                    blocks.append(
                        .toolUse(
                            ToolUseBlock(
                                id: toolID,
                                name: toolName,
                                input: Self.stringDictionary(from: block["args"] ?? block["input"])
                            )
                        )
                    )
                case "tool_use":
                    if let toolID = block["id"] as? String, seenToolIDs.contains(toolID) {
                        continue
                    }
                    if let toolID = block["id"] as? String {
                        seenToolIDs.insert(toolID)
                    }
                    if let toolName = block["name"] as? String,
                       let toolID = block["id"] as? String {
                        toolIDToName[toolID] = toolName
                    }
                    if let toolBlock = parseToolUse(block) {
                        blocks.append(.toolUse(toolBlock))
                    }
                default:
                    continue
                }
            }
        }

        guard !blocks.isEmpty else { return nil }
        return ChatMessage(id: messageID, role: chatRole, timestamp: timestamp, content: blocks, usage: nil)
    }

    private func parseCodeBuddyHistoryToolMessage(
        _ messageJSON: [String: Any],
        completedToolIDs: inout Set<String>,
        toolResults: inout [String: ToolResult],
        structuredResults: inout [String: ToolResultData],
        toolIDToName: inout [String: String]
    ) {
        guard let messageDict = Self.codeBuddyHistoryMessagePayload(from: messageJSON["message"]),
              let contentArray = messageDict["content"] as? [[String: Any]] else {
            return
        }

        for block in contentArray {
            guard
                block["type"] as? String == "tool-result",
                let toolID = (block["toolCallId"] as? String) ?? (block["tool_use_id"] as? String)
            else {
                continue
            }

            let toolName = (block["toolName"] as? String) ?? toolIDToName[toolID]
            if let toolName {
                toolIDToName[toolID] = toolName
            }

            let isError = block["isError"] as? Bool ?? block["is_error"] as? Bool ?? false
            let result = block["result"] as? [String: Any] ?? [:]
            let content = (result["content"] as? String)
                ?? (result["message"] as? String)
                ?? (result["listing"] as? String)
                ?? (result["path"] as? String)
                ?? Self.serializedJSONString(from: result)

            completedToolIDs.insert(toolID)
            toolResults[toolID] = ToolResult(
                content: content,
                stdout: result["stdout"] as? String,
                stderr: result["stderr"] as? String,
                isError: isError
            )

            if let toolName {
                structuredResults[toolID] = Self.parseStructuredResult(
                    toolName: toolName,
                    toolUseResult: result,
                    isError: isError
                )
            }
        }
    }

    private func sanitizedCodeBuddyHistoryText(_ text: String?) -> String? {
        guard let text else { return nil }

        if let extractedUserQuery = Self.extractTaggedText(
            from: text,
            startTag: "<user_query>",
            endTag: "</user_query>"
        ) {
            if let formattedQuestionAnswer = Self.formatQuestionAnswerPayload(extractedUserQuery) {
                return SessionTextSanitizer.sanitizedDisplayText(formattedQuestionAnswer)
            }
            return SessionTextSanitizer.sanitizedDisplayText(extractedUserQuery)
        }

        if let formattedQuestionAnswer = Self.formatQuestionAnswerPayload(text) {
            return SessionTextSanitizer.sanitizedDisplayText(formattedQuestionAnswer)
        }
        return SessionTextSanitizer.sanitizedDisplayText(text)
    }

    private static func extractTaggedText(
        from text: String,
        startTag: String,
        endTag: String
    ) -> String? {
        guard
            let startRange = text.range(of: startTag),
            let endRange = text.range(of: endTag, range: startRange.upperBound..<text.endIndex)
        else {
            return nil
        }

        let extracted = text[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? nil : String(extracted)
    }

    private static func formatQuestionAnswerPayload(_ text: String) -> String? {
        guard let payload = extractTaggedText(
            from: text,
            startTag: "<question_answer>",
            endTag: "</question_answer>"
        ) else {
            return nil
        }

        let questionItemPattern = #"<question_item\b[^>]*>([\s\S]*?)</question_item>"#
        guard let itemRegex = try? NSRegularExpression(pattern: questionItemPattern) else {
            return nil
        }

        let payloadRange = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        let itemMatches = itemRegex.matches(in: payload, range: payloadRange)
        guard !itemMatches.isEmpty else { return nil }

        let formattedSections = itemMatches.compactMap { match -> String? in
            guard
                let itemRange = Range(match.range(at: 1), in: payload),
                let question = extractTaggedText(
                    from: String(payload[itemRange]),
                    startTag: "<question>",
                    endTag: "</question>"
                )
            else {
                return nil
            }

            let answersText = extractTaggedText(
                from: String(payload[itemRange]),
                startTag: "<answers>",
                endTag: "</answers>"
            ) ?? ""

            let normalizedAnswers = answersText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")

            if normalizedAnswers.isEmpty {
                return "问题：\(question)"
            }

            return "问题：\(question)\n回答：\(normalizedAnswers)"
        }

        guard !formattedSections.isEmpty else { return nil }
        return formattedSections.joined(separator: "\n\n")
    }

    private static func codeBuddyHistoryMessagePayload(from rawValue: Any?) -> [String: Any]? {
        if let dict = rawValue as? [String: Any] {
            return dict
        }

        guard
            let string = rawValue as? String,
            let data = string.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return dict
    }

    private static func stringDictionary(from rawValue: Any?) -> [String: String] {
        guard let dictionary = rawValue as? [String: Any] else { return [:] }

        return dictionary.reduce(into: [String: String]()) { partial, entry in
            if let stringValue = entry.value as? String {
                partial[entry.key] = stringValue
            } else if let intValue = entry.value as? Int {
                partial[entry.key] = String(intValue)
            } else if let doubleValue = entry.value as? Double {
                partial[entry.key] = String(doubleValue)
            } else if let boolValue = entry.value as? Bool {
                partial[entry.key] = boolValue ? "true" : "false"
            } else if JSONSerialization.isValidJSONObject(entry.value),
                      let data = try? JSONSerialization.data(withJSONObject: entry.value, options: [.sortedKeys]),
                      let json = String(data: data, encoding: .utf8) {
                partial[entry.key] = json
            }
        }
    }

    private func codeBuddyHistoryTimestamp(from rawValue: Any?) -> Date? {
        if let timestamp = rawValue as? TimeInterval {
            return timestamp > 1_000_000_000_000
                ? Date(timeIntervalSince1970: timestamp / 1000)
                : Date(timeIntervalSince1970: timestamp)
        }

        if let timestamp = rawValue as? Int {
            return timestamp > 1_000_000_000_000
                ? Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
                : Date(timeIntervalSince1970: TimeInterval(timestamp))
        }

        if let string = rawValue as? String {
            if let timestamp = TimeInterval(string) {
                return timestamp > 1_000_000_000_000
                    ? Date(timeIntervalSince1970: timestamp / 1000)
                    : Date(timeIntervalSince1970: timestamp)
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string)
        }

        return nil
    }

    private static func serializedJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    func qoderFallbackIntervention(sessionId: String) -> SessionIntervention? {
        guard let historyPath = Self.qoderConversationHistoryPath(sessionId: sessionId),
              let content = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
            return nil
        }

        return Self.parseQoderConversationHistory(content)
    }

    func qoderFallbackSubagentPresentation(
        sessionId: String,
        cwd: String,
        explicitFilePath: String? = nil
    ) -> QoderSubagentPresentation? {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        guard Self.transcriptFormat(for: sessionFile) == .claudeLike,
              let content = try? String(contentsOfFile: sessionFile, encoding: .utf8) else {
            return nil
        }

        return Self.parseQoderSubagentPresentation(content)
    }

    func pendingCodeBuddyCLIQuestionIntervention(
        sessionId: String,
        cwd: String,
        explicitFilePath: String? = nil,
        actorName: String,
        responseToolUseId: String?
    ) -> SessionIntervention? {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        guard Self.transcriptFormat(for: sessionFile) == .claudeLike,
              let content = try? String(contentsOfFile: sessionFile, encoding: .utf8) else {
            return nil
        }

        return Self.parsePendingCodeBuddyCLIQuestionIntervention(
            content,
            sessionId: sessionId,
            actorName: actorName,
            responseToolUseId: responseToolUseId
        )
    }

    private struct PendingCodeBuddyCLIQuestion {
        let callId: String
        let toolName: String
        let arguments: [String: Any]
        let argumentsJSON: String
    }

    private static func parsePendingCodeBuddyCLIQuestionIntervention(
        _ content: String,
        sessionId: String,
        actorName: String,
        responseToolUseId: String?
    ) -> SessionIntervention? {
        var pending: PendingCodeBuddyCLIQuestion?
        var completedCallIds: Set<String> = []

        for line in content.components(separatedBy: .newlines) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let normalizedType = type
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if normalizedType == "function_call",
               let toolName = json["name"] as? String,
               codeBuddyQuestionToolNames.contains(normalizedToolName(toolName)),
               let callId = nonEmpty(json["callId"] as? String)
                    ?? nonEmpty(json["call_id"] as? String)
                    ?? nonEmpty(json["id"] as? String),
               let arguments = decodedJSONObject(from: json["arguments"]),
               let questions = decodedQuestions(from: arguments["questions"]),
               !questions.isEmpty,
               let argumentsJSON = serializedJSONString(from: arguments) {
                pending = PendingCodeBuddyCLIQuestion(
                    callId: callId,
                    toolName: toolName,
                    arguments: arguments,
                    argumentsJSON: argumentsJSON
                )
                continue
            }

            if isCodeBuddyCLIResultType(normalizedType),
               let callId = resultCallId(from: json) {
                completedCallIds.insert(callId)
                if pending?.callId == callId {
                    pending = nil
                }
            }
        }

        guard let pending,
              !completedCallIds.contains(pending.callId),
              let questions = decodedQuestions(from: pending.arguments["questions"]) else {
            return nil
        }

        let parsedQuestions = questions.enumerated().compactMap { index, question -> SessionInterventionQuestion? in
            codeBuddyCLIInterventionQuestion(from: question, index: index)
        }
        guard !parsedQuestions.isEmpty else { return nil }

        let title = parsedQuestions.count == 1
            ? "\(actorName) 的提问"
            : "\(actorName) 的提问（\(parsedQuestions.count) 个问题）"
        var metadata: [String: String] = [
            "source": "codebuddy_cli_transcript",
            "toolName": pending.toolName,
            "toolInputJSON": pending.argumentsJSON,
            "transcriptCallId": pending.callId
        ]
        if let responseToolUseId, !responseToolUseId.isEmpty {
            metadata["originalToolUseId"] = responseToolUseId
        } else {
            metadata["originalToolUseId"] = pending.callId
        }

        return SessionIntervention(
            id: responseToolUseId ?? pending.callId,
            kind: .question,
            title: title,
            message: "\(actorName) 需要你补充回答，提交后会继续执行当前会话。",
            options: [],
            questions: parsedQuestions,
            supportsSessionScope: false,
            metadata: metadata
        )
    }

    private static func codeBuddyCLIInterventionQuestion(
        from question: [String: Any],
        index: Int
    ) -> SessionInterventionQuestion? {
        let prompt = (question["question"] as? String)
            ?? (question["prompt"] as? String)
            ?? (question["label"] as? String)
        guard let prompt, !prompt.isEmpty else { return nil }

        let objectOptions = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { entry -> SessionInterventionOption? in
            let (optionIndex, option) = entry
            guard let label = option["label"] as? String, !label.isEmpty else { return nil }
            return SessionInterventionOption(
                id: option["id"] as? String ?? "\(index)-option-\(optionIndex)",
                title: label,
                detail: option["description"] as? String
            )
        }

        let options: [SessionInterventionOption]
        if !objectOptions.isEmpty {
            options = objectOptions
        } else if let stringOptions = question["options"] as? [String], !stringOptions.isEmpty {
            options = stringOptions.enumerated().map { optionIndex, label in
                SessionInterventionOption(
                    id: "\(index)-option-\(optionIndex)",
                    title: label,
                    detail: nil
                )
            }
        } else {
            options = []
        }

        return SessionInterventionQuestion(
            id: question["id"] as? String ?? prompt,
            header: question["header"] as? String ?? "\(index + 1).",
            prompt: prompt,
            detail: question["description"] as? String,
            options: options,
            allowsMultiple: question["isMultiple"] as? Bool
                ?? question["allowsMultiple"] as? Bool
                ?? question["multiSelect"] as? Bool
                ?? question["multiple"] as? Bool
                ?? false,
            allowsOther: true,
            isSecret: question["isSecret"] as? Bool
                ?? question["secret"] as? Bool
                ?? false
        )
    }

    private static func decodedJSONObject(from rawValue: Any?) -> [String: Any]? {
        if let dictionary = rawValue as? [String: Any] {
            return dictionary
        }

        guard let string = rawValue as? String,
              let data = string.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    private static func decodedQuestions(from rawValue: Any?) -> [[String: Any]]? {
        if let questions = rawValue as? [[String: Any]], !questions.isEmpty {
            return questions
        }
        if let question = rawValue as? [String: Any] {
            return [question]
        }
        guard let string = rawValue as? String,
              let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let questions = json as? [[String: Any]], !questions.isEmpty {
            return questions
        }
        if let question = json as? [String: Any] {
            return [question]
        }
        return nil
    }

    private static func isCodeBuddyCLIResultType(_ normalizedType: String) -> Bool {
        normalizedType == "function_call_output"
            || normalizedType == "function_result"
            || normalizedType == "tool_result"
            || normalizedType == "tool-result"
            || (normalizedType.contains("function") && (normalizedType.contains("output") || normalizedType.contains("result")))
            || (normalizedType.contains("tool") && normalizedType.contains("result"))
    }

    private static func resultCallId(from json: [String: Any]) -> String? {
        nonEmpty(json["callId"] as? String)
            ?? nonEmpty(json["call_id"] as? String)
            ?? nonEmpty(json["toolCallId"] as? String)
            ?? nonEmpty(json["tool_call_id"] as? String)
            ?? nonEmpty(json["toolUseId"] as? String)
            ?? nonEmpty(json["tool_use_id"] as? String)
            ?? nonEmpty(json["id"] as? String)
    }

    private static func normalizedToolName(_ toolName: String) -> String {
        toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func qoderConversationHistoryPath(sessionId: String) -> String? {
        let shortSessionId = String(sessionId.prefix(8))
        let rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/cache/projects", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newestMatch: URL?
        var newestDate = Date.distantPast

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "\(shortSessionId).txt",
                  fileURL.path.contains("/conversation-history/") else {
                continue
            }

            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            if newestMatch == nil || modifiedAt > newestDate {
                newestMatch = fileURL
                newestDate = modifiedAt
            }
        }

        return newestMatch?.path
    }

    private static func parseQoderConversationHistory(_ content: String) -> SessionIntervention? {
        struct RequestSection {
            let requestId: String
            let lines: [String]
        }

        let allLines = content.components(separatedBy: .newlines)
        var sections: [RequestSection] = []
        var currentRequestId: String?
        var currentLines: [String] = []

        for line in allLines {
            if line.hasPrefix("--- Request: "), line.hasSuffix(" ---") {
                if let currentRequestId {
                    sections.append(RequestSection(requestId: currentRequestId, lines: currentLines))
                }

                let requestId = line
                    .replacingOccurrences(of: "--- Request: ", with: "")
                    .replacingOccurrences(of: " ---", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentRequestId = requestId
                currentLines = []
                continue
            }

            if currentRequestId != nil {
                currentLines.append(line)
            }
        }

        if let currentRequestId {
            sections.append(RequestSection(requestId: currentRequestId, lines: currentLines))
        }

        guard let latestSection = sections.last else {
            return nil
        }

        let trimmedLines = latestSection.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let lastAskIndex = trimmedLines.lastIndex(of: "[Tool call] ask_user_question") else {
            return nil
        }

        let trailingLines = Array(trimmedLines.dropFirst(lastAskIndex + 1))
        let hasResolvedAskUserQuestion = trailingLines.contains("[Tool result] ask_user_question")
        guard !hasResolvedAskUserQuestion else {
            return nil
        }

        let questionCount = trailingLines
            .compactMap { line -> Int? in
                guard line.hasPrefix("questions: ["),
                      let start = line.firstIndex(of: "["),
                      let end = line[start...].firstIndex(of: " ") else {
                    return nil
                }
                return Int(line[line.index(after: start)..<end])
            }
            .first ?? 1

        let title = questionCount == 1
            ? "Qoder 的提问"
            : "Qoder 的提问（\(questionCount) 个问题）"

        return SessionIntervention(
            id: "qoder-question-\(latestSection.requestId)",
            kind: .question,
            title: title,
            message: "Qoder 已在 IDE 内弹出问题，请回到 Qoder 完成回答。Island 会继续保留提醒，直到会话继续推进。",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "responseMode": "external_only",
                "source": "qoderConversationHistory",
                "requestId": latestSection.requestId
            ]
        )
    }

    private static func parseQoderSubagentPresentation(_ content: String) -> QoderSubagentPresentation? {
        enum FirstMeaningfulContent {
            case displayableText
            case toolUse(name: String, input: [String: Any]?)
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var sawSessionMeta = false
        var sawDisplayableConversationText = false
        var firstMeaningfulContent: FirstMeaningfulContent?

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            if type == "session_meta" {
                sawSessionMeta = true
                break
            }

            guard let message = json["message"] as? [String: Any] else { continue }
            for block in contentBlocks(in: message) {
                let blockType = block["type"] as? String

                if blockType == "tool_use" {
                    let toolName = block["name"] as? String ?? "Tool"
                    let toolInput = block["input"] as? [String: Any]
                    if firstMeaningfulContent == nil {
                        firstMeaningfulContent = .toolUse(name: toolName, input: toolInput)
                    }
                    continue
                }

                guard blockType == "text",
                      let text = block["text"] as? String,
                      let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text),
                      isDisplayableText(sanitizedText) else {
                    continue
                }

                sawDisplayableConversationText = true
                if firstMeaningfulContent == nil {
                    firstMeaningfulContent = .displayableText
                }
            }
        }

        guard !sawSessionMeta, !sawDisplayableConversationText else { return nil }
        guard case .toolUse(let toolName, let toolInput)? = firstMeaningfulContent else { return nil }
        guard toolName.caseInsensitiveCompare("Agent") != .orderedSame else { return nil }
        guard let title = qoderFallbackSubagentTitle(toolName: toolName, input: toolInput) else { return nil }

        return QoderSubagentPresentation(displayTitle: title)
    }

    private static func qoderFallbackSubagentTitle(toolName: String, input: [String: Any]?) -> String? {
        let normalizedToolName = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToolName.isEmpty else { return nil }

        let inputSummary = formattedToolSummaryInput(input)
        if let inputSummary, !inputSummary.isEmpty {
            return "Agent · \(humanizedToolName(normalizedToolName)) \(inputSummary)"
        }

        return "Agent · \(humanizedToolName(normalizedToolName))"
    }

    private static func humanizedToolName(_ toolName: String) -> String {
        toolName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func formattedToolSummaryInput(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }

        let preferredPathKeys = [
            "file_path",
            "path",
            "target_file",
            "relative_workspace_path",
            "relative_path"
        ]
        for key in preferredPathKeys {
            if let path = input[key] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }

        let preferredStringKeys = [
            "description",
            "command",
            "pattern",
            "query",
            "url",
            "prompt"
        ]
        for key in preferredStringKeys {
            if let value = input[key] as? String,
               let sanitizedValue = SessionTextSanitizer.sanitizedDisplayText(value),
               !sanitizedValue.isEmpty {
                return truncateMessage(sanitizedValue, maxLength: 48)
            }
        }

        for (_, value) in input {
            if let value = value as? String,
               let sanitizedValue = SessionTextSanitizer.sanitizedDisplayText(value),
               !sanitizedValue.isEmpty {
                return truncateMessage(sanitizedValue, maxLength: 48)
            }
        }

        return nil
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            let sanitizedContent = SessionTextSanitizer.sanitizedDisplayText(content)
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            guard let sanitizedContent else { return nil }
            if sanitizedContent.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(sanitizedContent))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String,
                           let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text) {
                            if sanitizedText.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(sanitizedText))
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String,
                           let sanitizedThinking = SessionTextSanitizer.sanitizedDisplayText(thinking) {
                            blocks.append(.thinking(sanitizedThinking))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        let usage: MessageTokenUsage? = type == "assistant" ? Self.parseUsage(from: messageDict) : nil

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks,
            usage: usage
        )
    }

    private nonisolated static func parseUsage(from messageDict: [String: Any]) -> MessageTokenUsage? {
        guard let usageDict = messageDict["usage"] as? [String: Any] else { return nil }
        let inputTokens = usageDict["input_tokens"] as? Int ?? 0
        let outputTokens = usageDict["output_tokens"] as? Int ?? 0
        let cacheCreation = usageDict["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
        guard inputTokens > 0 || outputTokens > 0 || cacheCreation > 0 || cacheRead > 0 else { return nil }
        return MessageTokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead
        )
    }

    private func parseOpenClawMessageLine(_ json: [String: Any]) -> ChatMessage? {
        guard json["type"] as? String == "message",
              let id = json["id"] as? String,
              let messageDict = json["message"] as? [String: Any],
              let roleString = messageDict["role"] as? String else {
            return nil
        }

        let role: ChatRole
        switch roleString {
        case "user":
            role = .user
        case "assistant":
            role = .assistant
        default:
            role = .system
        }

        let timestamp: Date = {
            guard let timestampStr = json["timestamp"] as? String else { return Date() }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: timestampStr) ?? Date()
        }()

        var blocks: [MessageBlock] = []
        if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "text":
                    if let text = block["text"] as? String,
                       let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text) {
                        blocks.append(.text(sanitizedText))
                    }
                case "thinking":
                    if let thinking = block["thinking"] as? String,
                       let sanitizedThinking = SessionTextSanitizer.sanitizedDisplayText(thinking) {
                        blocks.append(.thinking(sanitizedThinking))
                    }
                default:
                    continue
                }
            }
        }

        guard !blocks.isEmpty else { return nil }
        return ChatMessage(id: id, role: role, timestamp: timestamp, content: blocks, usage: nil)
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                } else if JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                          let json = String(data: data, encoding: .utf8) {
                    input[key] = json
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    // MARK: - Structured Result Parsing

    /// Parse tool result JSON into structured ToolResultData
    private static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.dropFirst(5).split(separator: "_", maxSplits: 2)
            let serverName = parts.count > 0 ? String(parts[0]) : "unknown"
            let mcpToolName = parts.count > 1 ? String(parts[1].dropFirst()) : toolName
            return .mcp(MCPResult(
                serverName: serverName,
                toolName: mcpToolName,
                rawResult: toolUseResult
            ))
        }

        switch toolName {
        case "Read":
            return parseReadResult(toolUseResult)
        case "Edit":
            return parseEditResult(toolUseResult)
        case "Write":
            return parseWriteResult(toolUseResult)
        case "Bash":
            return parseBashResult(toolUseResult)
        case "Grep":
            return parseGrepResult(toolUseResult)
        case "Glob":
            return parseGlobResult(toolUseResult)
        case "TodoWrite":
            return parseTodoWriteResult(toolUseResult)
        case "Task":
            return parseTaskResult(toolUseResult)
        case "WebFetch":
            return parseWebFetchResult(toolUseResult)
        case "WebSearch":
            return parseWebSearchResult(toolUseResult)
        case "AskUserQuestion":
            return parseAskUserQuestionResult(toolUseResult)
        case "BashOutput":
            return parseBashOutputResult(toolUseResult)
        case "KillShell":
            return parseKillShellResult(toolUseResult)
        case "ExitPlanMode":
            return parseExitPlanModeResult(toolUseResult)
        default:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        }
    }

    // MARK: - Individual Tool Result Parsers

    private static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    private static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    private static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    private static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    private static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    private static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    private static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    private static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    private static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    private static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    private static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    private static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    private static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    private static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }

    // MARK: - Subagent Tools Parsing

    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                } else if JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                          let json = String(data: data, encoding: .utf8) {
                    input[key] = json
                }
            }
        }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Static Subagent Tools Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}
