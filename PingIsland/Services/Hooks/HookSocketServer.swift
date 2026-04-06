//
//  HookSocketServer.swift
//  PingIsland
//
//  Unix domain socket server for Claude bridge hook events.
//  The external hook protocol is the bridge envelope format only.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Hooks")

/// Event received from hook clients after bridge-envelope mapping.
struct HookEvent: Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let provider: SessionProvider
    let clientInfo: SessionClientInfo
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?

    init(
        sessionId: String,
        cwd: String,
        event: String,
        status: String,
        provider: SessionProvider,
        clientInfo: SessionClientInfo,
        pid: Int?,
        tty: String?,
        tool: String?,
        toolInput: [String: AnyCodable]?,
        toolUseId: String?,
        notificationType: String?,
        message: String?
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.provider = provider
        self.clientInfo = clientInfo
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    nonisolated var expectsResponse: Bool {
        let normalizedTool = tool?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
        return (event == "PermissionRequest" && status == "waiting_for_approval")
            || (
                event == "PreToolUse"
                    && normalizedTool == "askuserquestion"
                    && toolInput?["questions"] != nil
            )
    }
}

private extension HookEvent {
    func withToolUseId(_ toolUseId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: event,
            status: status,
            provider: provider,
            clientInfo: clientInfo,
            pid: pid,
            tty: tty,
            tool: tool,
            toolInput: toolInput,
            toolUseId: toolUseId,
            notificationType: notificationType,
            message: message
        )
    }
}

private enum BridgeProvider: String, Codable, Sendable {
    case claude
    case codex
}

private enum BridgeStatusKind: String, Codable, Sendable {
    case idle
    case active
    case thinking
    case runningTool
    case waitingForApproval
    case waitingForInput
    case compacting
    case completed
    case interrupted
    case notification
    case error
}

private struct BridgeStatus: Codable, Sendable {
    let kind: BridgeStatusKind
    let detail: String?
}

private struct BridgeTerminalContext: Codable, Sendable {
    let terminalProgram: String?
    let terminalBundleID: String?
    let ideName: String?
    let ideBundleID: String?
    let iTermSessionID: String?
    let terminalSessionID: String?
    let tty: String?
    let currentDirectory: String?
    let transport: String?
    let remoteHost: String?
    let tmuxSession: String?
    let tmuxPane: String?
}

private struct BridgeEnvelope: Codable, Sendable {
    let id: UUID
    let provider: BridgeProvider
    let eventType: String
    let sessionKey: String
    let title: String?
    let preview: String?
    let cwd: String?
    let status: BridgeStatus?
    let terminalContext: BridgeTerminalContext
    let expectsResponse: Bool
    let metadata: [String: String]
    let sentAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case eventType
        case sessionKey
        case title
        case preview
        case cwd
        case status
        case terminalContext
        case expectsResponse
        case metadata
        case sentAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(BridgeProvider.self, forKey: .provider)
        eventType = try container.decode(String.self, forKey: .eventType)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        status = try container.decodeIfPresent(BridgeStatus.self, forKey: .status)
        terminalContext = try container.decodeIfPresent(BridgeTerminalContext.self, forKey: .terminalContext)
            ?? BridgeTerminalContext(
                terminalProgram: nil,
                terminalBundleID: nil,
                ideName: nil,
                ideBundleID: nil,
                iTermSessionID: nil,
                terminalSessionID: nil,
                tty: nil,
                currentDirectory: nil,
                transport: nil,
                remoteHost: nil,
                tmuxSession: nil,
                tmuxPane: nil
            )

        var decodedMetadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        let expectation = try Self.decodeResponseExpectation(from: container)
        if decodedMetadata["tool_input_json"] == nil,
           let injectedToolInput = expectation.injectedToolInput,
           let encodedToolInput = Self.encodeToolInputJSON(injectedToolInput) {
            decodedMetadata["tool_input_json"] = encodedToolInput
        }

        expectsResponse = expectation.value
        metadata = decodedMetadata
        sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
    }

    private static func decodeResponseExpectation(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> (value: Bool, injectedToolInput: [String: Any]?) {
        if let expectsResponse = try? container.decode(Bool.self, forKey: .expectsResponse) {
            return (expectsResponse, nil)
        }

        if let questionArray = try? container.decode([AnyCodable].self, forKey: .expectsResponse) {
            let questions = questionArray.map(\.value)
            guard !questions.isEmpty else {
                return (false, nil)
            }
            return (true, ["questions": questions])
        }

        if let responseObject = try? container.decode([String: AnyCodable].self, forKey: .expectsResponse) {
            let normalizedObject = responseObject.mapValues(\.value)
            if normalizedObject["questions"] != nil {
                return (true, normalizedObject)
            }

            let looksLikeQuestion = [
                normalizedObject["question"],
                normalizedObject["prompt"],
                normalizedObject["header"],
                normalizedObject["options"]
            ].contains { $0 != nil }

            if looksLikeQuestion {
                return (true, ["questions": [normalizedObject]])
            }

            return (!normalizedObject.isEmpty, nil)
        }

        return (false, nil)
    }

    private static func encodeToolInputJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}

private enum BridgeDecision: String, Codable, Sendable {
    case approve
    case approveForSession
    case deny
    case cancel
    case answer
}

private struct BridgeResponse: Codable, Sendable {
    let requestID: UUID
    let decision: BridgeDecision?
    let reason: String?
    let updatedInput: [String: AnyCodable]?
    let errorMessage: String?
}

private extension BridgeEnvelope {
    var resolvedSessionID: String {
        let sessionId = metadata["session_id"]
            ?? metadata["thread_id"]
            ?? metadata["threadId"]
            ?? sessionKey.components(separatedBy: ":").dropFirst().joined(separator: ":")
        return sessionId.isEmpty ? sessionKey : sessionId
    }

    var hookEvent: HookEvent {
        let metadata = self.metadata
        let toolInput = Self.decodeToolInput(from: metadata["tool_input_json"])
        let sessionId = resolvedSessionID

        return HookEvent(
            sessionId: sessionId,
            cwd: cwd ?? terminalContext.currentDirectory ?? metadata["cwd"] ?? "",
            event: eventType,
            status: Self.mapStatus(eventType: eventType, status: status?.kind, notificationType: metadata["notification_type"]),
            provider: provider.sessionProvider,
            clientInfo: Self.makeClientInfo(
                provider: provider,
                sessionId: sessionId,
                terminalContext: terminalContext,
                metadata: metadata
            ),
            pid: Int(metadata["pid"] ?? ""),
            tty: terminalContext.tty,
            tool: Self.normalizedToolName(metadata["tool_name"] ?? title),
            toolInput: toolInput,
            toolUseId: metadata["tool_use_id"],
            notificationType: metadata["notification_type"],
            message: metadata["message"] ?? preview
        )
    }

    private static func mapStatus(
        eventType: String,
        status: BridgeStatusKind?,
        notificationType: String?
    ) -> String {
        if eventType == "Notification", notificationType == "idle_prompt" {
            return "waiting_for_input"
        }

        switch status {
        case .waitingForApproval:
            return "waiting_for_approval"
        case .waitingForInput:
            return "waiting_for_input"
        case .runningTool:
            return "running_tool"
        case .compacting:
            return "compacting"
        case .completed:
            return "ended"
        case .notification:
            return "notification"
        case .interrupted:
            return "waiting_for_input"
        case .idle:
            return "idle"
        case .thinking, .active, .error, .none:
            break
        }

        switch eventType {
        case "SessionEnd":
            return "ended"
        case "SessionStart", "Stop", "SubagentStop":
            return "waiting_for_input"
        case "UserPromptSubmit", "PostToolUse":
            return "processing"
        case "PreToolUse":
            return "running_tool"
        case "PreCompact":
            return "compacting"
        case "Notification":
            return "notification"
        default:
            return "processing"
        }
    }

    private static func decodeToolInput(from json: String?) -> [String: AnyCodable]? {
        guard let json, let data = json.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object.mapValues { AnyCodable($0) }
    }

    private static func normalizedToolName(_ rawToolName: String?) -> String? {
        guard let rawToolName else { return nil }
        switch rawToolName.lowercased() {
        case "ask_user_question", "askuserquestion":
            return "AskUserQuestion"
        default:
            return rawToolName
        }
    }

    private static func makeClientInfo(
        provider: BridgeProvider,
        sessionId: String,
        terminalContext: BridgeTerminalContext,
        metadata: [String: String]
    ) -> SessionClientInfo {
        let explicitKind = (
            metadata["client_kind"]
                ?? metadata["client_type"]
                ?? metadata["client"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let explicitName = firstNonEmpty(
            metadata["client_name"],
            metadata["client_title"],
            metadata["client"]
        )
        let explicitBundleID = firstNonEmpty(
            metadata["client_bundle_id"],
            metadata["source_bundle_id"]
        )
        let terminalBundleID = firstNonEmpty(
            terminalContext.ideBundleID,
            terminalContext.terminalBundleID
        )
        let explicitOrigin = firstNonEmpty(
            metadata["client_origin"],
            metadata["origin"],
            metadata["_source"]
        )
        let explicitOriginator = firstNonEmpty(
            metadata["client_originator"],
            metadata["originator"],
            metadata["source_title"],
            terminalContext.ideName
        )
        let explicitThreadSource = firstNonEmpty(
            metadata["thread_source"],
            metadata["session_start_source"],
            metadata["codex_session_start_source"]
        )
        let explicitTransport = firstNonEmpty(
            metadata["connection_transport"],
            terminalContext.transport
        )
        let remoteHost = firstNonEmpty(
            metadata["remote_host"],
            terminalContext.remoteHost
        )
        let sessionFilePath = firstNonEmpty(
            metadata["session_file_path"],
            metadata["rollout_path"],
            metadata["transcript_path"]
        )
        let launchURL = firstNonEmpty(
            metadata["launch_url"],
            metadata["deeplink"],
            metadata["deep_link"]
        )
        let processName = firstNonEmpty(
            metadata["source_process_name"],
            metadata["process_name"]
        )
        let hasExplicitNonTerminalBundle = explicitBundleID.map { !TerminalAppRegistry.isTerminalBundle($0) } ?? false
        let providerKind = provider.sessionProvider
        let matchedProfile = ClientProfileRegistry.matchRuntimeProfile(
            provider: providerKind,
            explicitKind: explicitKind,
            explicitName: explicitName,
            explicitBundleIdentifier: explicitBundleID,
            terminalBundleIdentifier: terminalBundleID,
            origin: explicitOrigin,
            originator: explicitOriginator,
            threadSource: explicitThreadSource,
            processName: processName
        )

        let kind: SessionClientKind
        switch provider {
        case .claude:
            if let matchedProfile {
                kind = matchedProfile.kind
            } else if explicitName != nil || hasExplicitNonTerminalBundle {
                kind = .custom
            } else {
                kind = .claudeCode
            }
        case .codex:
            if let matchedProfile {
                kind = matchedProfile.kind
            } else if explicitKind?.contains("app") == true
                || explicitKind?.contains("desktop") == true
                || hasExplicitNonTerminalBundle
                || explicitBundleID == "com.openai.codex" {
                kind = .codexApp
            } else if explicitKind?.contains("cli") == true
                || terminalContext.tty != nil
                || terminalContext.terminalProgram != nil
                || terminalContext.terminalBundleID != nil {
                kind = .codexCLI
            } else if explicitName != nil {
                kind = .custom
            } else {
                kind = .codexApp
            }
        }

        let resolvedBundleID: String?
        if kind == .codexApp {
            resolvedBundleID = explicitBundleID
                ?? terminalBundleID
                ?? matchedProfile?.defaultBundleIdentifier
                ?? "com.openai.codex"
        } else {
            resolvedBundleID = explicitBundleID
        }

        let resolvedName: String?
        if let explicitName {
            resolvedName = explicitName
        } else {
            resolvedName = matchedProfile?.displayName
                ?? (kind == .claudeCode ? "Claude Code" : nil)
        }

        let resolvedLaunchURL: String?
        if let launchURL {
            resolvedLaunchURL = launchURL
        } else if kind == .codexApp {
            resolvedLaunchURL = SessionClientInfo.appLaunchURL(
                bundleIdentifier: resolvedBundleID ?? "com.openai.codex",
                sessionId: sessionId,
                workspacePath: terminalContext.currentDirectory
            )
        } else if let workspaceLaunchURL = terminalBundleID.flatMap({
            SessionClientInfo.appLaunchURL(
                bundleIdentifier: $0,
                workspacePath: terminalContext.currentDirectory
            )
        }) {
            resolvedLaunchURL = workspaceLaunchURL
        } else {
            resolvedLaunchURL = nil
        }

        let resolvedOrigin: String?
        if let explicitOrigin {
            resolvedOrigin = explicitOrigin
        } else if provider == .codex {
            resolvedOrigin = matchedProfile?.defaultOrigin ?? (kind == .codexCLI ? "cli" : "desktop")
        } else {
            resolvedOrigin = nil
        }

        return SessionClientInfo(
            kind: kind,
            profileID: matchedProfile?.id,
            name: resolvedName,
            bundleIdentifier: resolvedBundleID,
            launchURL: resolvedLaunchURL,
            origin: resolvedOrigin,
            originator: explicitOriginator,
            threadSource: explicitThreadSource,
            transport: explicitTransport,
            remoteHost: remoteHost,
            sessionFilePath: sessionFilePath,
            terminalBundleIdentifier: terminalBundleID,
            terminalProgram: terminalContext.terminalProgram,
            terminalSessionIdentifier: terminalContext.terminalSessionID,
            iTermSessionIdentifier: terminalContext.iTermSessionID,
            tmuxSessionIdentifier: terminalContext.tmuxSession,
            tmuxPaneIdentifier: terminalContext.tmuxPane,
            processName: processName
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }
}

private extension BridgeProvider {
    var sessionProvider: SessionProvider {
        switch self {
        case .claude:
            return .claude
        case .codex:
            return .codex
        }
    }
}

struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let requestId: UUID
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

typealias HookEventHandler = @Sendable (HookEvent) -> Void
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/island.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.wudanwu.pingisland.socket", qos: .userInitiated)

    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private init() {}

    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendHookResponse(toolUseId: toolUseId, decision: decision, reason: reason, updatedInput: nil)
        }
    }

    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
        }
    }

    func respondToIntervention(toolUseId: String, decision: String, updatedInput: [String: Any]? = nil, reason: String? = nil) {
        queue.async { [weak self] in
            let encodedInput = updatedInput?.mapValues { AnyCodable($0) }
            self?.sendHookResponse(toolUseId: toolUseId, decision: decision, reason: reason, updatedInput: encodedInput)
        }
    }

    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(BridgeEnvelope.self, from: allData) else {
            logger.warning("Failed to parse bridge envelope: \(String(data: allData, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            return
        }

        let expectsResponse = envelope.expectsResponse || envelope.hookEvent.expectsResponse
        var event = envelope.hookEvent
        logger.debug("Received bridge envelope provider=\(envelope.provider.rawValue, privacy: .public) event=\(envelope.eventType, privacy: .public) session=\(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" && event.toolUseId == nil {
            let syntheticToolUseId = "bridge-\(envelope.id.uuidString)"
            event = event.withToolUseId(syntheticToolUseId)
            logger.debug("Generated synthetic tool_use_id for \(event.sessionId.prefix(8), privacy: .public) event=\(event.event, privacy: .public) id=\(syntheticToolUseId.prefix(12), privacy: .public)")
        } else if event.event == "PostToolUse",
                  event.toolUseId == nil,
                  let cachedToolUseId = popCachedToolUseId(event: event) {
            event = event.withToolUseId(cachedToolUseId)
        }

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
        }

        if expectsResponse {
            let toolUseId = event.toolUseId
                ?? popCachedToolUseId(event: event)
                ?? "bridge-\(envelope.id.uuidString)"
            let updatedEvent = event.toolUseId == toolUseId ? event : event.withToolUseId(toolUseId)

            let pending = PendingPermission(
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                requestId: envelope.id,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            logger.debug("Keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            eventHandler?(updatedEvent)
            return
        }

        close(clientSocket)
        eventHandler?(event)
    }

    private func bridgeDecision(for decision: String) -> BridgeDecision? {
        switch decision {
        case "allow", "approve":
            return .approve
        case "approveForSession", "allow_for_session":
            return .approveForSession
        case "deny":
            return .deny
        case "cancel", "ask":
            return .cancel
        case "answer":
            return .answer
        default:
            return nil
        }
    }

    private func sendHookResponse(toolUseId: String, decision: String, reason: String?, updatedInput: [String: AnyCodable]?) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        let response = BridgeResponse(
            requestID: pending.requestId,
            decision: bridgeDecision(for: decision),
            reason: reason,
            updatedInput: updatedInput,
            errorMessage: nil
        )
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(pending.sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending bridge response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(pending.sessionId, pending.toolUseId)
        }
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = BridgeResponse(
            requestID: pending.requestId,
            decision: bridgeDecision(for: decision),
            reason: reason,
            updatedInput: nil,
            errorMessage: nil
        )
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending bridge response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }
}

struct AnyCodable: Codable, @unchecked Sendable {
    nonisolated(unsafe) let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}
