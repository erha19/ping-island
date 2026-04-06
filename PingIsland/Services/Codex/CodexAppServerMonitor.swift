import Foundation
import os.log

actor CodexAppServerMonitor {
    static let shared = CodexAppServerMonitor()

    struct ThreadDiagnosticsSnapshot: Codable, Sendable {
        let threadId: String
        let name: String?
        let preview: String?
        let cwd: String?
        let path: String?
        let statusType: String?
        let isEphemeral: Bool
        let updatedAt: Date?
        let placeholderCandidate: Bool
    }

    private enum PendingRequestKind {
        case commandApproval
        case fileApproval
        case permissionsApproval
        case userInput
    }

    private struct PendingRequest {
        let requestId: String
        let threadId: String
        let kind: PendingRequestKind
        let intervention: SessionIntervention
        let requestedPermissions: [String: Any]?
    }

    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Codex")
    private let port = 41241

    private var process: Process?
    private var websocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var requestSequence = 0
    private var pendingResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingRequestsByThread: [String: PendingRequest] = [:]
    private var resolvedClientBundleIdentifier: String?
    private var resolvedClientName: String?
    private var lastThreadDiagnostics: [ThreadDiagnosticsSnapshot] = []

    private init() {}

    func start() async {
        if websocket != nil {
            return
        }

        if await connectToServer() {
            return
        }

        guard let executable = resolveCodexExecutable() else {
            logger.notice("Codex CLI not found; app-server monitor disabled")
            return
        }

        resolvedClientBundleIdentifier = Self.bundleIdentifier(forCodexExecutable: executable)
        resolvedClientName = Self.clientName(forCodexExecutable: executable)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            self.process = process
        } catch {
            logger.error("Failed to launch codex app-server: \(error.localizedDescription, privacy: .public)")
        }

        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            if await connectToServer() {
                return
            }
        }

        logger.error("Unable to connect to Codex app-server on port \(self.port)")
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil
        process?.terminate()
        process = nil
        pendingRequestsByThread.removeAll()
        lastThreadDiagnostics.removeAll()

        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: CancellationError())
        }
        pendingResponses.removeAll()
    }

    func approve(threadId: String, forSession: Bool) async {
        guard let pending = pendingRequestsByThread[threadId] else { return }
        let result: [String: Any]

        switch pending.kind {
        case .commandApproval:
            result = ["decision": forSession ? "acceptForSession" : "accept"]
        case .fileApproval:
            result = ["decision": forSession ? "acceptForSession" : "accept"]
        case .permissionsApproval:
            result = [
                "permissions": pending.requestedPermissions ?? [:],
                "scope": forSession ? "session" : "turn"
            ]
        case .userInput:
            return
        }

        await sendResponse(id: pending.requestId, result: result)
        pendingRequestsByThread.removeValue(forKey: threadId)
        await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
    }

    func deny(threadId: String) async {
        guard let pending = pendingRequestsByThread[threadId] else { return }
        let result: [String: Any]

        switch pending.kind {
        case .commandApproval:
            result = ["decision": "decline"]
        case .fileApproval:
            result = ["decision": "decline"]
        case .permissionsApproval:
            result = [
                "permissions": [:],
                "scope": "turn"
            ]
        case .userInput:
            return
        }

        await sendResponse(id: pending.requestId, result: result)
        pendingRequestsByThread.removeValue(forKey: threadId)
        await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
    }

    func answer(threadId: String, answers: [String: [String]]) async {
        guard let pending = pendingRequestsByThread[threadId], pending.kind == .userInput else { return }

        let formattedAnswers = answers.reduce(into: [String: Any]()) { partial, entry in
            partial[entry.key] = ["answers": entry.value]
        }

        await sendResponse(
            id: pending.requestId,
            result: ["answers": formattedAnswers]
        )
        pendingRequestsByThread.removeValue(forKey: threadId)
        await SessionStore.shared.resolveCodexIntervention(sessionId: threadId, nextPhase: .processing)
    }

    func readThread(threadId: String, includeTurns: Bool = true) async throws -> CodexThreadSnapshot {
        if websocket == nil {
            await start()
        }

        let response = try await sendRequest(
            method: "thread/read",
            params: [
                "threadId": threadId,
                "includeTurns": includeTurns
            ]
        )

        guard let thread = response["thread"] as? [String: Any],
              let snapshot = parseThreadSnapshot(thread) else {
            throw NSError(domain: "CodexAppServer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid thread/read response"
            ])
        }

        await SessionStore.shared.syncCodexThreadSnapshot(snapshot)
        return snapshot
    }

    func continueThread(threadId: String, expectedTurnId: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if websocket == nil {
            await start()
        }

        _ = try await sendRequest(
            method: "turn/steer",
            params: [
                "threadId": threadId,
                "expectedTurnId": expectedTurnId,
                "input": [
                    [
                        "type": "text",
                        "text": trimmed
                    ]
                ]
            ]
        )

        await SessionStore.shared.upsertCodexSession(
            sessionId: threadId,
            name: nil,
            preview: trimmed,
            cwd: nil,
            phase: .processing,
            intervention: nil
        )
    }

    func diagnosticsSnapshot() -> [ThreadDiagnosticsSnapshot] {
        lastThreadDiagnostics
    }

    private func connectToServer() async -> Bool {
        guard websocket == nil else { return true }
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return false }

        let websocket = URLSession.shared.webSocketTask(with: url)
        websocket.resume()
        self.websocket = websocket

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "Island",
                        "title": "Island",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
                    ],
                    "capabilities": [
                        "experimentalApi": true
                    ]
                ]
            )

            if let response = try? await sendRequest(
                method: "thread/list",
                params: [
                    "archived": false,
                    "limit": 30,
                    "sortKey": "updated_at"
                ]
            ) {
                await ingestThreadList(response)
            }

            return true
        } catch {
            logger.debug("Codex websocket initialize failed: \(error.localizedDescription, privacy: .public)")
            receiveTask?.cancel()
            receiveTask = nil
            websocket.cancel(with: .goingAway, reason: nil)
            self.websocket = nil
            return false
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let websocket else { return }

            do {
                let message = try await websocket.receive()
                await handle(message)
            } catch {
                logger.debug("Codex websocket closed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }

        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let method = json["method"] as? String {
            if let idValue = json["id"] {
                await handleServerRequest(
                    id: stringify(idValue),
                    method: method,
                    params: json["params"] as? [String: Any] ?? [:]
                )
            } else {
                await handleNotification(method: method, params: json["params"] as? [String: Any] ?? [:])
            }
            return
        }

        guard let idValue = json["id"] else { return }
        let id = stringify(idValue)

        if let continuation = pendingResponses.removeValue(forKey: id) {
            if let result = json["result"] as? [String: Any] {
                continuation.resume(returning: result)
            } else if json["result"] is NSNull {
                continuation.resume(returning: [:])
            } else if let errorObject = json["error"] as? [String: Any] {
                let message = (errorObject["message"] as? String) ?? "Unknown Codex app-server error"
                continuation.resume(throwing: NSError(domain: "CodexAppServer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ]))
            } else {
                continuation.resume(returning: [:])
            }
        }
    }

    private func handleNotification(method: String, params: [String: Any]) async {
        logger.info("Codex notification method=\(method, privacy: .public)")
        switch method {
        case "thread/status/changed":
            let threadId = (params["threadId"] as? String) ?? ""
            guard !threadId.isEmpty else { return }
            let statusType = ((params["status"] as? [String: Any])?["type"] as? String) ?? "unknown"
            logger.info(
                "Codex status changed thread=\(threadId, privacy: .public) statusType=\(statusType, privacy: .public)"
            )
            let phase = phaseFromCodexStatus(
                params["status"] as? [String: Any],
                threadId: threadId,
                intervention: pendingRequestsByThread[threadId]?.intervention
            )
            let hasExistingSession = await SessionStore.shared.containsSession(threadId)
            if !hasExistingSession, pendingRequestsByThread[threadId] == nil {
                logger.notice(
                    "Ignoring status-only update for unknown Codex thread=\(threadId, privacy: .public) statusType=\(statusType, privacy: .public)"
                )
                return
            }
            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: nil,
                cwd: nil,
                phase: phase,
                intervention: pendingRequestsByThread[threadId]?.intervention
            )

        case "thread/started":
            if let thread = params["thread"] as? [String: Any] {
                let startedThreadId = (thread["id"] as? String) ?? "unknown"
                let namePresent = (thread["name"] as? String)?.isEmpty == false
                let previewPresent = (thread["preview"] as? String)?.isEmpty == false
                let pathPresent = (thread["path"] as? String)?.isEmpty == false
                logger.info(
                    "Codex thread started thread=\(startedThreadId, privacy: .public) namePresent=\(namePresent, privacy: .public) previewPresent=\(previewPresent, privacy: .public) pathPresent=\(pathPresent, privacy: .public)"
                )
                await ingestThread(thread)
            }

        case "thread/name/updated":
            guard let threadId = params["threadId"] as? String else { return }
            await SessionStore.shared.updateCodexThreadName(
                sessionId: threadId,
                name: params["threadName"] as? String
            )

        case "thread/archived":
            guard let threadId = params["threadId"] as? String else { return }
            logger.info("Codex thread archived thread=\(threadId, privacy: .public)")
            removeThreadDiagnostics(threadId: threadId)
            await SessionStore.shared.process(.sessionEnded(sessionId: threadId))

        default:
            break
        }
    }

    private func handleServerRequest(id: String, method: String, params: [String: Any]) async {
        switch method {
        case "item/commandExecution/requestApproval":
            let threadId = (params["threadId"] as? String) ?? (params["conversationId"] as? String) ?? ""
            guard !threadId.isEmpty else { return }

            let command = ((params["command"] as? [String]) ?? []).joined(separator: " ")
            let cwd = params["cwd"] as? String
            let reason = params["reason"] as? String
            let intervention = SessionIntervention(
                id: id,
                kind: .approval,
                title: "Approve Command",
                message: reason ?? (command.isEmpty ? "Codex wants to run a terminal command." : command),
                options: [],
                questions: [],
                supportsSessionScope: true,
                metadata: [
                    "command": command,
                    "cwd": cwd ?? ""
                ]
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .commandApproval,
                intervention: intervention,
                requestedPermissions: nil
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: command.isEmpty ? reason : command,
                cwd: cwd,
                phase: .waitingForApproval(PermissionContext(
                    toolUseId: params["callId"] as? String ?? id,
                    toolName: "exec_command",
                    toolInput: nil,
                    receivedAt: Date()
                )),
                intervention: intervention
            )

        case "item/fileChange/requestApproval":
            guard let threadId = params["threadId"] as? String else { return }
            let reason = params["reason"] as? String
            let grantRoot = params["grantRoot"] as? String
            let intervention = SessionIntervention(
                id: id,
                kind: .approval,
                title: "Approve File Changes",
                message: reason ?? grantRoot ?? "Codex wants to modify files in this workspace.",
                options: [],
                questions: [],
                supportsSessionScope: true,
                metadata: [
                    "grantRoot": grantRoot ?? ""
                ]
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .fileApproval,
                intervention: intervention,
                requestedPermissions: nil
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: reason ?? grantRoot,
                cwd: nil,
                phase: .waitingForApproval(PermissionContext(
                    toolUseId: params["itemId"] as? String ?? id,
                    toolName: "file_change",
                    toolInput: nil,
                    receivedAt: Date()
                )),
                intervention: intervention
            )

        case "item/permissions/requestApproval":
            guard let threadId = params["threadId"] as? String else { return }
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            let reason = params["reason"] as? String
            let message = reason ?? permissionSummary(permissions)
            let intervention = SessionIntervention(
                id: id,
                kind: .approval,
                title: "Approve Permissions",
                message: message,
                options: [],
                questions: [],
                supportsSessionScope: true,
                metadata: [:]
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .permissionsApproval,
                intervention: intervention,
                requestedPermissions: permissions
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: message,
                cwd: nil,
                phase: .waitingForApproval(PermissionContext(
                    toolUseId: params["itemId"] as? String ?? id,
                    toolName: "permissions_request",
                    toolInput: nil,
                    receivedAt: Date()
                )),
                intervention: intervention
            )

        case "item/tool/requestUserInput":
            guard let threadId = params["threadId"] as? String else { return }
            let questions = parseQuestions(params["questions"] as? [[String: Any]] ?? [])
            let prompt = questions.first?.prompt ?? "Codex needs your input."
            let intervention = SessionIntervention(
                id: id,
                kind: .question,
                title: "Codex Needs Input",
                message: prompt,
                options: questions.first?.options ?? [],
                questions: questions,
                supportsSessionScope: false,
                metadata: [
                    "turnId": params["turnId"] as? String ?? "",
                    "itemId": params["itemId"] as? String ?? ""
                ]
            )

            pendingRequestsByThread[threadId] = PendingRequest(
                requestId: id,
                threadId: threadId,
                kind: .userInput,
                intervention: intervention,
                requestedPermissions: nil
            )

            await SessionStore.shared.upsertCodexSession(
                sessionId: threadId,
                name: nil,
                preview: prompt,
                cwd: nil,
                phase: .waitingForInput,
                intervention: intervention
            )

        default:
            break
        }
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let websocket else {
            throw NSError(domain: "CodexAppServer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Websocket not connected"
            ])
        }

        requestSequence += 1
        let id = String(requestSequence)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            Task {
                do {
                    try await websocket.send(.data(data))
                } catch {
                    if let continuation = pendingResponses.removeValue(forKey: id) {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func sendResponse(id: String, result: [String: Any]) async {
        guard let websocket else { return }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }

        do {
            try await websocket.send(.data(data))
        } catch {
            logger.error("Failed to send Codex response: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ingestThreadList(_ response: [String: Any]) async {
        guard let data = response["data"] as? [[String: Any]] else { return }
        lastThreadDiagnostics = data.map(Self.makeThreadDiagnosticsSnapshot(from:))
        logger.info("Codex thread list received count=\(data.count, privacy: .public)")
        for thread in data {
            await ingestThread(thread)
        }
    }

    private func ingestThread(_ thread: [String: Any]) async {
        guard let threadId = thread["id"] as? String else { return }
        let name = thread["name"] as? String
        let preview = thread["preview"] as? String
        let cwd = thread["cwd"] as? String
        let clientInfo = makeClientInfo(from: thread, threadId: threadId)
        let phase = phaseFromCodexStatus(
            thread["status"] as? [String: Any],
            threadId: threadId,
            intervention: pendingRequestsByThread[threadId]?.intervention
        )
        let diagnostics = Self.makeThreadDiagnosticsSnapshot(from: thread)
        recordThreadDiagnostics(diagnostics)
        let pathPresent = (thread["path"] as? String)?.isEmpty == false

        logger.info(
            "Codex ingest thread=\(threadId, privacy: .public) phase=\(String(describing: phase), privacy: .public) namePresent=\(name?.isEmpty == false, privacy: .public) previewPresent=\(preview?.isEmpty == false, privacy: .public) cwd=\((cwd ?? ""), privacy: .public) pathPresent=\(pathPresent, privacy: .public) ephemeral=\(diagnostics.isEphemeral, privacy: .public) placeholderCandidate=\(diagnostics.placeholderCandidate, privacy: .public)"
        )
        if diagnostics.placeholderCandidate {
            logger.notice("Codex ingest placeholder candidate thread=\(threadId, privacy: .public)")
        }

        await SessionStore.shared.upsertCodexSession(
            sessionId: threadId,
            name: name,
            preview: preview,
            cwd: cwd,
            phase: phase,
            intervention: pendingRequestsByThread[threadId]?.intervention,
            clientInfo: clientInfo,
            activityAt: diagnostics.updatedAt
        )
    }

    private func recordThreadDiagnostics(_ snapshot: ThreadDiagnosticsSnapshot) {
        if let existingIndex = lastThreadDiagnostics.firstIndex(where: { $0.threadId == snapshot.threadId }) {
            lastThreadDiagnostics[existingIndex] = snapshot
        } else {
            lastThreadDiagnostics.insert(snapshot, at: 0)
        }
    }

    private func removeThreadDiagnostics(threadId: String) {
        lastThreadDiagnostics.removeAll { $0.threadId == threadId }
    }

    private static func makeThreadDiagnosticsSnapshot(from thread: [String: Any]) -> ThreadDiagnosticsSnapshot {
        func normalize(_ text: String?) -> String? {
            guard let text else { return nil }
            let collapsed = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? nil : collapsed
        }

        func date(from rawValue: Any?) -> Date? {
            if let value = rawValue as? NSNumber {
                return Date(timeIntervalSince1970: value.doubleValue)
            }
            if let value = rawValue as? Double {
                return Date(timeIntervalSince1970: value)
            }
            if let value = rawValue as? Int {
                return Date(timeIntervalSince1970: TimeInterval(value))
            }
            return nil
        }

        let threadId = thread["id"] as? String ?? "unknown"
        let name = normalize(thread["name"] as? String)
        let preview = normalize(thread["preview"] as? String)
        let cwd = normalize(thread["cwd"] as? String)
        let path = normalize(thread["path"] as? String)
        let statusType = (thread["status"] as? [String: Any])?["type"] as? String
        let isEphemeral = thread["ephemeral"] as? Bool ?? false
        let updatedAt = date(from: thread["updatedAt"])
        let placeholderCandidate =
            !isEphemeral
            && (name?.isEmpty != false)
            && (preview?.isEmpty != false)
            && (path?.isEmpty != false)
            && (statusType != "active" || {
                guard let updatedAt else { return false }
                return Date().timeIntervalSince(updatedAt) >= 60
            }())

        return ThreadDiagnosticsSnapshot(
            threadId: threadId,
            name: name,
            preview: preview,
            cwd: cwd,
            path: path,
            statusType: statusType,
            isEphemeral: isEphemeral,
            updatedAt: updatedAt,
            placeholderCandidate: placeholderCandidate
        )
    }

    private func parseThreadSnapshot(_ thread: [String: Any]) -> CodexThreadSnapshot? {
        guard let threadId = thread["id"] as? String else { return nil }

        let createdAt = date(fromUnixTimestamp: thread["createdAt"]) ?? Date()
        let updatedAt = date(fromUnixTimestamp: thread["updatedAt"]) ?? createdAt
        let status = thread["status"] as? [String: Any]
        let phase = phaseFromCodexStatus(
            status,
            threadId: threadId,
            intervention: pendingRequestsByThread[threadId]?.intervention
        )
        let turns = thread["turns"] as? [[String: Any]] ?? []

        var historyItems: [ChatHistoryItem] = []
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessageDate: Date?
        var latestUserText: String?
        var latestAgentText: String?
        var latestAgentPhase: String?
        var latestFinalText: String?
        var latestFinalPhase: String?
        var latestTurnId: String?
        var itemOffset: TimeInterval = 0

        for (turnIndex, turn) in turns.enumerated() {
            if turnIndex == turns.count - 1 {
                latestTurnId = turn["id"] as? String
            }

            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items {
                itemOffset += 1
                let timestamp = createdAt.addingTimeInterval(itemOffset)
                let itemId = item["id"] as? String ?? UUID().uuidString

                switch item["type"] as? String {
                case "userMessage":
                    let text = parseUserMessageText(item["content"] as? [[String: Any]] ?? [])
                    guard let text else { continue }

                    if firstUserMessage == nil {
                        firstUserMessage = text
                    }
                    latestUserText = text
                    lastMessage = text
                    lastMessageRole = "user"
                    lastUserMessageDate = timestamp
                    historyItems.append(ChatHistoryItem(id: itemId, type: .user(text), timestamp: timestamp))

                case "agentMessage":
                    guard let text = sanitizedText(item["text"] as? String) else { continue }
                    let messagePhase = item["phase"] as? String
                    latestAgentText = text
                    latestAgentPhase = messagePhase
                    if messagePhase != "commentary" {
                        latestFinalText = text
                        latestFinalPhase = messagePhase
                    }

                    lastMessage = text
                    lastMessageRole = "assistant"
                    let type: ChatHistoryItemType = messagePhase == "commentary" ? .thinking(text) : .assistant(text)
                    historyItems.append(ChatHistoryItem(id: itemId, type: type, timestamp: timestamp))

                default:
                    continue
                }
            }
        }

        let preview = sanitizedText(thread["preview"] as? String)
        let summary = sanitizedText(thread["name"] as? String) ?? preview ?? firstUserMessage
        let conversationInfo = ConversationInfo(
            summary: summary,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )

        return CodexThreadSnapshot(
            threadId: threadId,
            name: sanitizedText(thread["name"] as? String),
            preview: preview,
            cwd: (thread["cwd"] as? String) ?? "/",
            clientInfo: makeClientInfo(from: thread, threadId: threadId),
            createdAt: createdAt,
            updatedAt: updatedAt,
            phase: phase,
            historyItems: historyItems,
            conversationInfo: conversationInfo,
            latestTurnId: latestTurnId,
            latestResponseText: latestFinalText ?? latestAgentText ?? preview,
            latestResponsePhase: latestFinalPhase ?? latestAgentPhase,
            latestUserText: latestUserText
        )
    }

    private func phaseFromCodexStatus(
        _ status: [String: Any]?,
        threadId: String,
        intervention: SessionIntervention?
    ) -> SessionPhase {
        if intervention?.kind == .approval {
            return .waitingForApproval(PermissionContext(
                toolUseId: intervention?.id ?? "codex-approval-\(threadId)",
                toolName: intervention?.title ?? "approval",
                toolInput: nil,
                receivedAt: Date()
            ))
        }

        guard let type = status?["type"] as? String else {
            if intervention?.kind == .question {
                return .waitingForInput
            }
            return .idle
        }

        if type == "active" {
            let flags = status?["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") {
                return .waitingForApproval(PermissionContext(
                    toolUseId: intervention?.id ?? "codex-approval-\(threadId)",
                    toolName: intervention?.title ?? "approval",
                    toolInput: nil,
                    receivedAt: Date()
                ))
            }
            if flags.contains("waitingOnUserInput") {
                return .waitingForInput
            }
            return .processing
        }

        if type == "systemError" {
            return .idle
        }

        return .idle
    }

    private func parseQuestions(_ rawQuestions: [[String: Any]]) -> [SessionInterventionQuestion] {
        rawQuestions.map { question in
            let options = (question["options"] as? [[String: Any]] ?? []).enumerated().map { index, option in
                SessionInterventionOption(
                    id: option["label"] as? String ?? "option-\(index)",
                    title: option["label"] as? String ?? "Option \(index + 1)",
                    detail: option["description"] as? String
                )
            }

            return SessionInterventionQuestion(
                id: question["id"] as? String ?? UUID().uuidString,
                header: question["header"] as? String ?? "Question",
                prompt: question["question"] as? String ?? "",
                detail: nil,
                options: options,
                allowsMultiple: question["isMultiple"] as? Bool
                    ?? question["allowsMultiple"] as? Bool
                    ?? question["multiSelect"] as? Bool
                    ?? question["multiple"] as? Bool
                    ?? false,
                allowsOther: question["isOther"] as? Bool ?? false,
                isSecret: question["isSecret"] as? Bool ?? false
            )
        }
    }

    private func makeClientInfo(from thread: [String: Any], threadId: String) -> SessionClientInfo {
        let origin = sanitizedText(thread["origin"] as? String)
            ?? sanitizedText(thread["clientOrigin"] as? String)
        let originator = sanitizedText(thread["originator"] as? String)
            ?? sanitizedText(thread["clientOriginator"] as? String)
        let threadSource = sanitizedText(thread["threadSource"] as? String)
            ?? sanitizedText(thread["source"] as? String)
            ?? sanitizedText(thread["sessionStartSource"] as? String)
        let sessionFilePath = sanitizedText(thread["rolloutPath"] as? String)
            ?? sanitizedText(thread["sessionFilePath"] as? String)
            ?? sanitizedText(thread["rollout_path"] as? String)

        let resolvedOrigin = origin ?? "desktop"

        let inferredKind: SessionClientKind
        if resolvedOrigin.localizedCaseInsensitiveContains("cli") {
            inferredKind = .codexCLI
        } else {
            inferredKind = .codexApp
        }

        let defaultInfo = inferredKind == .codexApp
            ? SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: resolvedClientName ?? "Codex App",
                bundleIdentifier: resolvedClientBundleIdentifier ?? "com.openai.codex",
                launchURL: SessionClientInfo.appLaunchURL(
                    bundleIdentifier: resolvedClientBundleIdentifier ?? "com.openai.codex",
                    sessionId: threadId
                ),
                origin: "desktop"
            )
            : SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI")

        return defaultInfo.merged(with: SessionClientInfo(
            kind: inferredKind,
            profileID: inferredKind == .codexApp ? "codex-app" : "codex-cli",
            name: originator ?? defaultInfo.name,
            bundleIdentifier: inferredKind == .codexApp ? defaultInfo.bundleIdentifier : nil,
            launchURL: inferredKind == .codexApp ? defaultInfo.launchURL : nil,
            origin: resolvedOrigin,
            originator: originator,
            threadSource: threadSource,
            sessionFilePath: sessionFilePath
        ))
    }

    private func permissionSummary(_ permissions: [String: Any]) -> String {
        var parts: [String] = []

        if let fileSystem = permissions["fileSystem"] as? [String: Any] {
            if let read = fileSystem["read"] as? [String], !read.isEmpty {
                parts.append("Read: \(read.joined(separator: ", "))")
            }
            if let write = fileSystem["write"] as? [String], !write.isEmpty {
                parts.append("Write: \(write.joined(separator: ", "))")
            }
        }

        if let network = permissions["network"] as? [String: Any],
           let enabled = network["enabled"] as? Bool {
            parts.append(enabled ? "Network access requested" : "Network access disabled")
        }

        return parts.isEmpty ? "Codex requested extra permissions." : parts.joined(separator: "\n")
    }

    private func parseUserMessageText(_ content: [[String: Any]]) -> String? {
        let fragments = content.compactMap { item -> String? in
            switch item["type"] as? String {
            case "text":
                return sanitizedText(item["text"] as? String)
            case "image":
                return "[Image]"
            case "localImage":
                if let path = item["path"] as? String {
                    return "[Image] \(URL(fileURLWithPath: path).lastPathComponent)"
                }
                return "[Image]"
            case "mention", "skill":
                return sanitizedText(item["name"] as? String)
            default:
                return nil
            }
        }

        guard !fragments.isEmpty else { return nil }
        return sanitizedText(fragments.joined(separator: "\n"))
    }

    private func sanitizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed.isEmpty ? nil : collapsed
    }

    private func date(fromUnixTimestamp rawValue: Any?) -> Date? {
        if let value = rawValue as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        if let value = rawValue as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = rawValue as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    private func stringify(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func resolveCodexExecutable() -> String? {
        let bundled = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        for searchRoot in [
            "/Applications",
            "\(NSHomeDirectory())/Applications"
        ] {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: searchRoot),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "app" {
                    enumerator.skipDescendants()
                    let candidate = fileURL
                        .appendingPathComponent("Contents", isDirectory: true)
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("codex")
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        return candidate.path
                    }
                }
            }
        }

        return Foundation.ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/codex" }
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func bundleIdentifier(forCodexExecutable executable: String) -> String? {
        let executableURL = URL(fileURLWithPath: executable)
        guard executableURL.path.contains(".app/") else { return nil }
        let appPath = executableURL.path.components(separatedBy: "/Contents/").first ?? ""
        guard !appPath.isEmpty else { return nil }
        return Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
    }

    private static func clientName(forCodexExecutable executable: String) -> String? {
        let executableURL = URL(fileURLWithPath: executable)
        guard executableURL.path.contains(".app/") else { return nil }
        let appPath = executableURL.path.components(separatedBy: "/Contents/").first ?? ""
        guard !appPath.isEmpty,
              let bundle = Bundle(url: URL(fileURLWithPath: appPath)) else {
            return nil
        }

        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
