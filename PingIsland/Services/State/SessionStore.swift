//
//  SessionStore.swift
//  PingIsland
//
//  Central state manager for all tracked sessions.
//  Single source of truth - all state mutations flow through process().
//

import AppKit
import Combine
import Foundation
import os.log

/// Central state manager for all tracked sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    struct SessionDiagnosticsSnapshot: Codable, Sendable {
        let sessionId: String
        let provider: String
        let ingress: String
        let phase: String
        let cwd: String
        let projectName: String
        let displayTitle: String
        let sessionName: String?
        let previewText: String?
        let lastMessage: String?
        let clientKind: String
        let clientName: String?
        let sessionFilePath: String?
        let hasIntervention: Bool
        let chatItemCount: Int
        let lastActivity: Date
        let createdAt: Date
        let isLikelyEmptyCodexPlaceholder: Bool
    }

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]
    private var pendingCodexPlaceholderPrunes: [String: Task<Void, Never>] = [:]
    private var pendingQoderConversationPolls: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var codexSessionAliases: [String: String] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000
    private let codexHookPlaceholderPruneDelayNs: UInt64 = 10_000_000_000
    private let codexAppServerPlaceholderPruneDelayNs: UInt64 = 60_000_000_000
    private let codexContinuationMergeWindow: TimeInterval = 10 * 60
    private let qoderConversationPollIntervalNs: UInt64 = 250_000_000
    private let qoderConversationPollTimeoutNs: UInt64 = 120_000_000_000

    /// Persisted session associations used to restore client routing across relaunches.
    private var persistedAssociations: [String: PersistedSessionAssociation] = [:]
    private var didLoadPersistedAssociations = false
    private var pendingAssociationSave: Task<Void, Never>?

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .interventionResolved(let sessionId, let nextPhase, let submittedAnswers):
            await processInterventionResolved(
                sessionId: sessionId,
                nextPhase: nextPhase,
                submittedAnswers: submittedAnswers
            )

        case .pruneTimedOutExternalContinuations(let now):
            await processTimedOutExternalContinuations(now: now)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .sessionArchived(let sessionId):
            await archiveSession(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.provider == .codex
            ? resolveOrAdoptCodexHookSession(event)
            : event.sessionId
        if shouldIgnoreCodexHookEvent(event, existingSession: sessions[sessionId]) {
            Self.logger.notice(
                "Ignoring weak Codex hook event session=\(sessionId, privacy: .public) event=\(event.event, privacy: .public) status=\(event.status, privacy: .public)"
            )
            return
        }
        var session = sessions[sessionId] ?? createSession(from: event)
        let tree = (event.pid != nil || event.tty != nil) ? ProcessTreeBuilder.shared.buildTree() : [:]

        session.provider = event.provider
        session.clientInfo = session.clientInfo.merged(with: event.clientInfo)
        session.clientInfo = normalizedClientInfo(session.clientInfo, provider: event.provider, sessionId: sessionId)
        session.ingress = .hookBridge
        session.pid = event.pid
        if let pid = event.pid {
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        if let runtimeClientInfo = await runtimeClientInfo(for: session, tree: tree) {
            session.clientInfo = session.clientInfo.merged(with: runtimeClientInfo)
            session.clientInfo = normalizedClientInfo(session.clientInfo, provider: event.provider, sessionId: sessionId)
        }
        await TerminalAutomationPermissionCoordinator.shared.prepareIfNeeded(
            provider: event.provider,
            clientInfo: session.clientInfo,
            sessionId: sessionId
        )
        session.lastActivity = Date()
        if let hookMessage = Self.normalizedHookMessage(event.message) {
            session.latestHookMessage = hookMessage
        }

        if event.status == "ended" {
            markSessionEnded(&session)
            sessions[sessionId] = session
            publishState()
            cancelPendingCodexPlaceholderPrune(sessionId: sessionId)
            cancelPendingQoderConversationPoll(sessionId: sessionId)
            scheduleFinalSessionSync(for: session)
            return
        }

        let newPhase = event.determinePhase()
        let intervention = event.intervention
        let shouldPreservePendingApproval = shouldPreservePendingApproval(for: event, session: session)

        if shouldPreservePendingApproval {
            Self.logger.debug(
                "Preserving waitingForApproval for \(sessionId.prefix(8), privacy: .public) on \(event.event, privacy: .public)"
            )
        } else if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        if let intervention {
            if session.clientInfo.brand == .qoder, intervention.kind == .question {
                session.intervention = mergedQoderQuestionIntervention(
                    current: session.intervention,
                    proposed: intervention
                )
            } else {
                session.intervention = intervention
            }
        } else if shouldClearIntervention(for: event, newPhase: newPhase, currentIntervention: session.intervention) {
            session.intervention = nil
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(event: event, session: &session, preservingPendingApproval: shouldPreservePendingApproval)
        processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        sessions[sessionId] = session
        publishState()
        updateCodexPlaceholderPrune(for: session)
        updateQoderConversationPoll(for: session, event: event)

        if event.shouldSyncFile {
            scheduleFileSync(
                sessionId: sessionId,
                cwd: event.cwd,
                explicitFilePath: session.clientInfo.sessionFilePath
            )
        } else if event.provider == .codex,
                  event.event != "SessionEnd",
                  let sessionFilePath = session.clientInfo.sessionFilePath,
                  !sessionFilePath.isEmpty {
            scheduleCodexRolloutSync(
                sessionId: sessionId,
                clientInfo: session.clientInfo,
                cwd: session.cwd
            )
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        let restoredAssociation = persistedAssociation(for: event.provider, sessionId: event.sessionId)
        let resolvedCwd = event.cwd.isEmpty ? (restoredAssociation?.cwd ?? "") : event.cwd
        let projectName = restoredAssociation?.projectName
            ?? Self.projectName(for: resolvedCwd, fallback: event.provider.displayName)
        let restoredClientInfo = restoredAssociation?.clientInfo ?? SessionClientInfo.default(for: event.provider)
        let resolvedClientInfo = normalizedClientInfo(
            restoredClientInfo.merged(with: event.clientInfo),
            provider: event.provider,
            sessionId: event.sessionId
        )

        return SessionState(
            sessionId: event.sessionId,
            cwd: resolvedCwd,
            projectName: projectName,
            provider: event.provider,
            clientInfo: resolvedClientInfo,
            ingress: .hookBridge,
            sessionName: restoredAssociation?.sessionName,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        processToolTracking(event: event, session: &session, preservingPendingApproval: false)
    }

    private func processToolTracking(
        event: HookEvent,
        session: inout SessionState,
        preservingPendingApproval: Bool
    ) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if preservingPendingApproval {
                return
            }
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func shouldPreservePendingApproval(for event: HookEvent, session: SessionState) -> Bool {
        guard event.event == "PostToolUse",
              let activePermission = session.activePermission,
              let toolUseId = event.toolUseId
        else {
            return false
        }

        return activePermission.toolUseId == toolUseId
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if event.tool == "Task", let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            }

        case "PostToolUse":
            if event.tool == "Task" {
                Self.logger.debug("PostToolUse for Task received (subagent still running)")
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        if status == .error {
            session.completedErrorToolIDs.insert(toolId)
        }
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        if result.status == .error {
            session.completedErrorToolIDs.insert(toolUseId)
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionId] = session
    }

    private func processInterventionResolved(
        sessionId: String,
        nextPhase: SessionPhase,
        submittedAnswers: [String: [String]]?
    ) async {
        guard var session = sessions[sessionId] else { return }
        if let intervention = session.intervention,
           intervention.kind == .question,
           (session.clientInfo.profileID == "qoderwork" || session.clientInfo.bundleIdentifier == "com.qoder.work"),
           intervention.supportsInlineResponse == false {
            session.intervention = intervention.markingAwaitingExternalContinuation(
                actorName: session.interactionDisplayName,
                selectedAnswers: submittedAnswers
            )
            session.phase = .waitingForInput
        } else {
            session.intervention = nil
            if session.phase.canTransition(to: nextPhase) || session.phase == nextPhase {
                session.phase = nextPhase
            }
        }
        session.lastActivity = Date()
        sessions[sessionId] = session
        publishState()
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }
        let previousPhase = session.phase
        let previousIntervention = session.intervention

        if !payload.messages.isEmpty {
            session.lastActivity = Date()
        }

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.sessionId,
            cwd: session.cwd,
            explicitFilePath: session.clientInfo.sessionFilePath
        )
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        await applyQoderFallbackIntervention(to: &session)

        if payload.isIncremental,
           let continuationAnsweredAt = session.intervention?.externalContinuationAnsweredAt,
           session.intervention?.awaitsExternalContinuation == true,
           payload.messages.contains(where: { $0.timestamp >= continuationAnsweredAt }) {
            session.intervention = nil
            if session.phase == .waitingForInput {
                session.phase = .processing
            }
        }

        sessions[payload.sessionId] = session
        if session.phase != previousPhase || session.intervention != previousIntervention {
            publishState()
        }

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    private func processTimedOutExternalContinuations(now: Date) async {
        var didChange = false

        for sessionId in sessions.keys {
            guard var session = sessions[sessionId],
                  session.intervention?.awaitsExternalContinuation == true,
                  session.intervention?.hasTimedOutExternalContinuation(now: now) == true else {
                continue
            }

            session.intervention = nil
            if session.phase == .waitingForInput {
                session.phase = .processing
            }
            session.lastActivity = now
            sessions[sessionId] = session
            didChange = true
        }

        if didChange {
            publishState()
        }
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    private func shouldClearIntervention(for event: HookEvent, newPhase: SessionPhase, currentIntervention: SessionIntervention?) -> Bool {
        guard currentIntervention?.kind == .question else { return false }
        if currentIntervention?.awaitsExternalContinuation == true,
           (event.clientInfo.profileID == "qoderwork" || event.clientInfo.bundleIdentifier == "com.qoder.work") {
            if event.event == "SessionEnd" {
                return true
            }
            return false
        }
        if event.event == "PostToolUse" || event.event == "Stop" || event.event == "SessionEnd" {
            return true
        }
        if event.isAskUserQuestionRequest {
            return false
        }
        return newPhase != .waitingForInput
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        session.lastActivity = Date()
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        guard var session = sessions[resolvedSessionId] else {
            cancelPendingSync(sessionId: resolvedSessionId)
            cancelPendingCodexPlaceholderPrune(sessionId: resolvedSessionId)
            cancelPendingQoderConversationPoll(sessionId: resolvedSessionId)
            return
        }

        markSessionEnded(&session)
        sessions[resolvedSessionId] = session
        cancelPendingCodexPlaceholderPrune(sessionId: resolvedSessionId)
        cancelPendingQoderConversationPoll(sessionId: resolvedSessionId)
        scheduleFinalSessionSync(for: session)
    }

    private func archiveSession(sessionId: String) async {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        sessions.removeValue(forKey: resolvedSessionId)
        clearCodexSessionAliases(for: resolvedSessionId)
        cancelPendingSync(sessionId: resolvedSessionId)
        cancelPendingCodexPlaceholderPrune(sessionId: resolvedSessionId)
        cancelPendingQoderConversationPoll(sessionId: resolvedSessionId)
    }

    private func markSessionEnded(_ session: inout SessionState) {
        session.phase = .ended
        session.intervention = nil
        session.lastActivity = Date()
    }

    private func scheduleFinalSessionSync(for session: SessionState) {
        if let sessionFilePath = session.clientInfo.sessionFilePath, !sessionFilePath.isEmpty {
            if session.provider == .codex {
                scheduleCodexRolloutSync(
                    sessionId: session.sessionId,
                    clientInfo: session.clientInfo,
                    cwd: session.cwd
                )
            } else {
                scheduleFileSync(
                    sessionId: session.sessionId,
                    cwd: session.cwd,
                    explicitFilePath: sessionFilePath
                )
            }
            return
        }

        if session.provider == .claude, !session.cwd.isEmpty {
            scheduleFileSync(sessionId: session.sessionId, cwd: session.cwd)
        }
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: sessions[sessionId]?.clientInfo.sessionFilePath
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: sessions[sessionId]?.clientInfo.sessionFilePath
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        await applyQoderFallbackIntervention(to: &session)

        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String, explicitFilePath: String? = nil) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd,
                explicitFilePath: explicitFilePath
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    private func updateQoderConversationPoll(for session: SessionState, event: HookEvent) {
        guard session.clientInfo.brand == .qoder else {
            cancelPendingQoderConversationPoll(sessionId: session.sessionId)
            return
        }

        if session.phase == .ended || event.event == "Stop" || event.status == "ended" {
            cancelPendingQoderConversationPoll(sessionId: session.sessionId)
            return
        }

        guard event.event == "UserPromptSubmit" else { return }
        scheduleQoderConversationPoll(sessionId: session.sessionId)
    }

    private func scheduleQoderConversationPoll(sessionId: String) {
        cancelPendingQoderConversationPoll(sessionId: sessionId)

        let pollID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }

            let startedAt = Date()
            while !Task.isCancelled {
                guard let session = await self.session(for: sessionId),
                      session.clientInfo.brand == .qoder,
                      session.phase != .ended else {
                    break
                }

                await self.refreshQoderFallbackState(sessionId: sessionId)

                if Date().timeIntervalSince(startedAt) * 1_000_000_000 >= Double(self.qoderConversationPollTimeoutNs) {
                    break
                }

                try? await Task.sleep(nanoseconds: self.qoderConversationPollIntervalNs)
            }

            await self.finishQoderConversationPoll(sessionId: sessionId, pollID: pollID)
        }

        pendingQoderConversationPolls[sessionId] = (id: pollID, task: task)
    }

    private func cancelPendingQoderConversationPoll(sessionId: String) {
        pendingQoderConversationPolls[sessionId]?.task.cancel()
        pendingQoderConversationPolls.removeValue(forKey: sessionId)
    }

    private func finishQoderConversationPoll(sessionId: String, pollID: UUID) {
        guard pendingQoderConversationPolls[sessionId]?.id == pollID else { return }
        pendingQoderConversationPolls.removeValue(forKey: sessionId)
    }

    private func refreshQoderFallbackState(sessionId: String) async {
        guard var session = sessions[sessionId], session.clientInfo.brand == .qoder else { return }

        let previousPhase = session.phase
        let previousIntervention = session.intervention
        await applyQoderFallbackIntervention(to: &session)

        guard session.phase != previousPhase || session.intervention != previousIntervention else {
            return
        }

        sessions[sessionId] = session
        publishState()
    }

    private func scheduleCodexRolloutSync(
        sessionId: String,
        clientInfo: SessionClientInfo,
        cwd: String
    ) {
        cancelPendingSync(sessionId: sessionId)

        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            guard let snapshot = await CodexRolloutParser.shared.parseThread(
                threadId: sessionId,
                fallbackCwd: cwd,
                clientInfo: clientInfo
            ) else {
                return
            }

            await self?.syncCodexThreadSnapshot(snapshot, ingress: .hookBridge)
        }
    }

    // MARK: - State Publishing

    private func publishState() {
        let prunedPlaceholderSessionIDs = pruneExpiredCodexHookPlaceholders(referenceDate: Date())
        let sortedSessions = Array(sessions.values).sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention
            }
            if lhs.phase.isActive != rhs.phase.isActive {
                return lhs.phase.isActive
            }
            return lhs.lastActivity > rhs.lastActivity
        }

        var shouldPersistAssociations = false
        for sessionId in prunedPlaceholderSessionIDs {
            if removePersistedAssociation(provider: .codex, sessionId: sessionId) {
                shouldPersistAssociations = true
            }
        }
        for session in sortedSessions {
            if updatePersistedAssociationIfNeeded(from: session) {
                shouldPersistAssociations = true
            }
        }

        if shouldPersistAssociations {
            scheduleAssociationSave()
        }

        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        return sessions[resolvedSessionId]
    }

    func resolvedCodexSessionId(for sessionId: String) -> String {
        resolveCodexSessionAlias(sessionId)
    }

    /// Check whether a session exists without requiring `SessionState` equality.
    func containsSession(_ sessionId: String) -> Bool {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        return sessions.keys.contains(resolvedSessionId)
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }

    func requestFileSync(for sessionId: String) {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        guard let session = sessions[resolvedSessionId] else { return }

        if session.provider == .codex {
            scheduleCodexRolloutSync(
                sessionId: resolvedSessionId,
                clientInfo: session.clientInfo,
                cwd: session.cwd
            )
            return
        }

        scheduleFileSync(
            sessionId: resolvedSessionId,
            cwd: session.cwd,
            explicitFilePath: session.clientInfo.sessionFilePath
        )
    }

    func diagnosticsSnapshot() -> [SessionDiagnosticsSnapshot] {
        sessions.values
            .sorted { $0.lastActivity > $1.lastActivity }
            .map { session in
                SessionDiagnosticsSnapshot(
                    sessionId: session.sessionId,
                    provider: session.provider.rawValue,
                    ingress: session.ingress.rawValue,
                    phase: String(describing: session.phase),
                    cwd: session.cwd,
                    projectName: session.projectName,
                    displayTitle: session.displayTitle,
                    sessionName: session.sessionName,
                    previewText: session.previewText,
                    lastMessage: session.lastMessage,
                    clientKind: session.clientInfo.kind.rawValue,
                    clientName: session.clientInfo.name,
                    sessionFilePath: session.clientInfo.sessionFilePath,
                    hasIntervention: session.intervention != nil,
                    chatItemCount: session.chatItems.count,
                    lastActivity: session.lastActivity,
                    createdAt: session.createdAt,
                    isLikelyEmptyCodexPlaceholder: isLikelyEmptyCodexPlaceholder(session)
                )
            }
    }

    // MARK: - Codex Integration

    func upsertCodexSession(
        sessionId: String,
        name: String?,
        preview: String?,
        cwd: String?,
        phase: SessionPhase,
        intervention: SessionIntervention?,
        clientInfo: SessionClientInfo? = nil,
        activityAt: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        let resolvedSessionId = resolveOrAdoptCodexSession(
            incomingSessionId: sessionId,
            name: name,
            preview: preview,
            cwd: cwd,
            phase: phase,
            clientInfo: clientInfo,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            activityAt: activityAt ?? Date(),
            ingress: .codexAppServer
        )
        let restoredAssociation = persistedAssociation(for: .codex, sessionId: resolvedSessionId)
        let initialCwd = cwd ?? sessions[resolvedSessionId]?.cwd ?? restoredAssociation?.cwd ?? "/"
        let initialProject = restoredAssociation?.projectName
            ?? Self.projectName(for: initialCwd, fallback: name ?? "Codex")
        let resolvedClientInfo = normalizedCodexClientInfo(
            restored: restoredAssociation?.clientInfo,
            incoming: clientInfo,
            sessionId: sessionId
        )

        var session = sessions[resolvedSessionId] ?? SessionState(
            sessionId: resolvedSessionId,
            cwd: initialCwd,
            projectName: initialProject,
            provider: .codex,
            clientInfo: resolvedClientInfo,
            ingress: .codexAppServer,
            sessionName: name ?? restoredAssociation?.sessionName,
            previewText: preview,
            intervention: intervention,
            phase: phase
        )

        session.provider = .codex
        session.clientInfo = normalizedClientInfo(
            session.clientInfo.merged(with: resolvedClientInfo),
            provider: .codex,
            sessionId: sessionId
        )
        if let cwd, !cwd.isEmpty {
            session.cwd = cwd
            session.projectName = Self.projectName(for: cwd, fallback: session.projectName)
        }
        if let name, !name.isEmpty {
            session.sessionName = name
        }
        if let preview, !preview.isEmpty {
            session.previewText = preview
        }
        session.intervention = intervention
        if session.phase.canTransition(to: phase) || session.phase == phase {
            session.phase = phase
        } else {
            session.phase = phase
        }
        let hasIntervention: Bool
        if case .some = session.intervention {
            hasIntervention = true
        } else {
            hasIntervention = false
        }
        if session.ingress != .hookBridge || (!session.phase.needsAttention && !hasIntervention) {
            session.ingress = .codexAppServer
        }
        session.lastActivity = activityAt ?? Date()

        if !metadata.isEmpty {
            var previewMetadata = session.previewText ?? ""
            if previewMetadata.isEmpty, let reason = metadata["reason"] {
                previewMetadata = reason
            }
            if !previewMetadata.isEmpty {
                session.previewText = previewMetadata
            }
        }

        let placeholderCandidate = isLikelyEmptyCodexPlaceholder(session)
        Self.logger.info(
            "Codex upsert session=\(resolvedSessionId, privacy: .public) sourceThread=\(sessionId, privacy: .public) phase=\(String(describing: session.phase), privacy: .public) ingress=\(session.ingress.rawValue, privacy: .public) namePresent=\(name?.isEmpty == false, privacy: .public) previewPresent=\(preview?.isEmpty == false, privacy: .public) cwd=\(session.cwd, privacy: .public) filePathPresent=\(session.clientInfo.sessionFilePath?.isEmpty == false, privacy: .public) placeholderCandidate=\(placeholderCandidate, privacy: .public)"
        )
        if placeholderCandidate {
            Self.logger.notice(
                "Codex placeholder candidate retained session=\(resolvedSessionId, privacy: .public) project=\(session.projectName, privacy: .public) displayTitle=\(session.displayTitle, privacy: .public)"
            )
        }

        sessions[resolvedSessionId] = session
        publishState()
        updateCodexPlaceholderPrune(for: session)
    }

    func updateCodexThreadName(sessionId: String, name: String?) {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        guard var session = sessions[resolvedSessionId] else { return }
        session.sessionName = name
        session.lastActivity = Date()
        sessions[resolvedSessionId] = session
        publishState()
    }

    func syncCodexThreadSnapshot(
        _ snapshot: CodexThreadSnapshot,
        ingress: SessionIngress = .codexAppServer
    ) {
        let resolvedSessionId = ingress == .codexAppServer
            ? resolveOrAdoptCodexSession(
                incomingSessionId: snapshot.threadId,
                name: snapshot.name,
                preview: snapshot.displayResultText ?? snapshot.preview,
                cwd: snapshot.cwd,
                phase: snapshot.phase,
                clientInfo: snapshot.clientInfo,
                conversationInfo: snapshot.conversationInfo,
                activityAt: snapshot.updatedAt,
                ingress: ingress
            )
            : resolveCodexSessionAlias(snapshot.threadId)
        let restoredAssociation = persistedAssociation(for: .codex, sessionId: resolvedSessionId)
        let fallbackCwd = snapshot.cwd.isEmpty
            ? (sessions[resolvedSessionId]?.cwd ?? restoredAssociation?.cwd ?? "/")
            : snapshot.cwd
        let fallbackName = snapshot.name ?? snapshot.preview ?? "Codex"
        let projectName = restoredAssociation?.projectName
            ?? Self.projectName(for: fallbackCwd, fallback: fallbackName)
        let resolvedClientInfo = normalizedCodexClientInfo(
            restored: restoredAssociation?.clientInfo,
            incoming: snapshot.clientInfo,
            sessionId: snapshot.threadId
        )

        var session = sessions[resolvedSessionId] ?? SessionState(
            sessionId: resolvedSessionId,
            cwd: fallbackCwd,
            projectName: projectName,
            provider: .codex,
            clientInfo: resolvedClientInfo,
            ingress: .codexAppServer,
            sessionName: snapshot.name ?? restoredAssociation?.sessionName,
            previewText: snapshot.preview,
            phase: snapshot.phase
        )

        session.provider = .codex
        session.clientInfo = normalizedClientInfo(
            session.clientInfo.merged(with: resolvedClientInfo),
            provider: .codex,
            sessionId: snapshot.threadId
        )
        session.cwd = fallbackCwd
        session.projectName = Self.projectName(for: fallbackCwd, fallback: session.projectName)
        if let name = snapshot.name, !name.isEmpty {
            session.sessionName = name
        }
        if let preview = snapshot.displayResultText, !preview.isEmpty {
            session.previewText = preview
        } else if let preview = snapshot.preview, !preview.isEmpty {
            session.previewText = preview
        }
        session.chatItems = snapshot.historyItems
        session.conversationInfo = snapshot.conversationInfo
        if case .none = session.intervention {
            session.phase = snapshot.phase
        }
        let hasIntervention: Bool
        if case .some = session.intervention {
            hasIntervention = true
        } else {
            hasIntervention = false
        }
        if ingress == .hookBridge {
            if session.ingress != .codexAppServer {
                session.ingress = .hookBridge
            }
        } else if session.ingress != .hookBridge || (!session.phase.needsAttention && !hasIntervention) {
            session.ingress = .codexAppServer
        }
        session.lastActivity = snapshot.updatedAt

        let placeholderCandidate = isLikelyEmptyCodexPlaceholder(session)
        Self.logger.info(
            "Codex snapshot sync session=\(resolvedSessionId, privacy: .public) sourceThread=\(snapshot.threadId, privacy: .public) ingress=\(ingress.rawValue, privacy: .public) historyItems=\(snapshot.historyItems.count, privacy: .public) namePresent=\(snapshot.name?.isEmpty == false, privacy: .public) previewPresent=\(snapshot.preview?.isEmpty == false, privacy: .public) filePathPresent=\(session.clientInfo.sessionFilePath?.isEmpty == false, privacy: .public) placeholderCandidate=\(placeholderCandidate, privacy: .public)"
        )

        sessions[resolvedSessionId] = session
        publishState()
        updateCodexPlaceholderPrune(for: session)
    }

    func resolveCodexIntervention(sessionId: String, nextPhase: SessionPhase = .processing) {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        guard var session = sessions[resolvedSessionId] else { return }
        session.intervention = nil
        session.phase = nextPhase
        session.lastActivity = Date()
        sessions[resolvedSessionId] = session
        publishState()
    }

    private nonisolated static func projectName(for cwd: String, fallback: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? fallback : name
    }

    private nonisolated static func normalizedHookMessage(_ message: String?) -> String? {
        SessionTextSanitizer.sanitizedDisplayText(message)
    }

    private func persistedAssociation(for provider: SessionProvider, sessionId: String) -> PersistedSessionAssociation? {
        ensurePersistedAssociationsLoaded()
        return persistedAssociations[SessionAssociationStore.cacheKey(provider: provider, sessionId: sessionId)]
    }

    private func applyQoderFallbackIntervention(to session: inout SessionState) async {
        guard session.clientInfo.brand == .qoder else { return }

        let fallbackSources: Set<String> = [
            "qoderConversationHistory",
            "qoderTranscriptIntent"
        ]
        let currentSource = session.intervention?.metadata["source"]

        if let currentSource, !fallbackSources.contains(currentSource) {
            return
        }

        let questionToolStatuses = session.chatItems.compactMap { item -> ToolStatus? in
            guard case .toolCall(let tool) = item.type else { return nil }
            let normalizedName = tool.name
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
            guard normalizedName == "askuserquestion" else { return nil }
            return tool.status
        }
        let hasAnyQuestionTool = !questionToolStatuses.isEmpty
        let hasResolvedQuestionTool = questionToolStatuses.contains { status in
            switch status {
            case .success, .error, .interrupted:
                return true
            case .running, .waitingForApproval:
                return false
            }
        }

        if session.phase == .ended || hasResolvedQuestionTool {
            if currentSource.map({ fallbackSources.contains($0) }) == true {
                session.intervention = nil
            }
            return
        }

        let fallbackIntervention = await ConversationParser.shared.qoderFallbackIntervention(sessionId: session.sessionId)

        if let fallbackIntervention {
            session.intervention = mergedQoderQuestionIntervention(
                current: session.intervention,
                proposed: fallbackIntervention
            )
            session.phase = .waitingForInput
            session.lastActivity = Date()
            return
        }

        if !hasAnyQuestionTool, let transcriptFallbackIntervention = qoderTranscriptQuestionIntervention(for: session) {
            session.intervention = mergedQoderQuestionIntervention(
                current: session.intervention,
                proposed: transcriptFallbackIntervention
            )
            session.phase = .waitingForInput
            session.lastActivity = Date()
            return
        }

        guard currentSource.map({ fallbackSources.contains($0) }) == true else { return }

        session.intervention = nil
        if session.phase == .waitingForInput {
            session.phase = .processing
        }
    }

    private func qoderTranscriptQuestionIntervention(for session: SessionState) -> SessionIntervention? {
        guard let intent = latestQoderQuestionIntent(in: session) else {
            return nil
        }

        let likelyPromptedQuestionRequest = [
            session.firstUserMessage,
            session.lastMessageRole == "user" ? session.lastMessage : nil
        ]
        .compactMap { $0 }
        .contains { text in
            looksLikeQoderQuestionPromptRequest(text)
        }

        guard likelyPromptedQuestionRequest else { return nil }

        let title = intent.questionCount == 1
            ? "Qoder 的提问"
            : "Qoder 的提问（\(intent.questionCount) 个问题）"

        return SessionIntervention(
            id: "qoder-question-intent-\(session.sessionId)",
            kind: .question,
            title: title,
            message: "Qoder 似乎正在 IDE 内等待你的回答，请回到 Qoder 完成输入。Island 会继续保留提醒，直到会话继续推进。",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "responseMode": "external_only",
                "source": "qoderTranscriptIntent",
                "promptText": intent.text
            ]
        )
    }

    private func latestQoderQuestionIntent(in session: SessionState) -> (text: String, questionCount: Int)? {
        for item in session.chatItems.reversed() {
            if case .assistant(let text) = item.type {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let questionCount = qoderQuestionIntentCount(in: trimmed) {
                    return (trimmed, questionCount)
                }
            }
        }

        guard session.lastMessageRole == "assistant",
              let lastMessage = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              let questionCount = qoderQuestionIntentCount(in: lastMessage) else {
            return nil
        }
        return (lastMessage, questionCount)
    }

    private func qoderQuestionIntentCount(in text: String) -> Int? {
        let normalizedText = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedText.isEmpty else { return nil }

        if normalizedText.contains("ask_user_question")
            || normalizedText.contains("问您一个问题")
            || normalizedText.contains("问你一个问题")
            || normalizedText.contains("需要您回答")
            || normalizedText.contains("需要你回答")
            || normalizedText.contains("ask you a question") {
            return 1
        }

        for pattern in [
            #"询问\s*(\d+)\s*个问题"#,
            #"问(?:您|你)\s*(\d+)\s*个问题"#,
            #"ask you\s*(\d+)\s*questions?"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                   in: normalizedText,
                   range: NSRange(normalizedText.startIndex..., in: normalizedText)
               ),
               let range = Range(match.range(at: 1), in: normalizedText),
               let count = Int(normalizedText[range]),
               count > 0 {
                return count
            }
        }

        if normalizedText.contains("使用提问工具向您询问")
            || normalizedText.contains("使用提问工具向你询问")
            || normalizedText.contains("提问工具向您询问")
            || normalizedText.contains("提问工具向你询问") {
            return 1
        }

        return nil
    }

    private func looksLikeQoderQuestionPromptRequest(_ text: String) -> Bool {
        let normalizedText = text.lowercased()
        if normalizedText.contains("问我一个问题")
            || normalizedText.contains("使用工具问我一个问题")
            || normalizedText.contains("ask me a question") {
            return true
        }

        for pattern in [
            #"问我\s*\d+\s*个问题"#,
            #"使用工具问我\s*\d+\s*个问题"#,
            #"ask me\s*\d+\s*questions?"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(
                   in: normalizedText,
                   range: NSRange(normalizedText.startIndex..., in: normalizedText)
               ) != nil {
                return true
            }
        }

        return false
    }

    private func mergedQoderQuestionIntervention(
        current: SessionIntervention?,
        proposed: SessionIntervention
    ) -> SessionIntervention {
        if let current,
           current.kind == .question,
           current.awaitsExternalContinuation,
           current.questions.map(\.mergeSignature) == proposed.questions.map(\.mergeSignature) {
            return current
        }

        guard proposed.kind == .question,
              let current,
              current.kind == .question,
              let currentSource = current.metadata["source"],
              currentSource == "qoderTranscriptIntent" || currentSource == "qoderConversationHistory" else {
            return proposed
        }

        return SessionIntervention(
            id: current.id,
            kind: proposed.kind,
            title: proposed.title,
            message: proposed.message,
            options: proposed.options,
            questions: proposed.questions,
            supportsSessionScope: proposed.supportsSessionScope,
            metadata: proposed.metadata
        )
    }

    private func ensurePersistedAssociationsLoaded() {
        guard !didLoadPersistedAssociations else { return }
        persistedAssociations = SessionAssociationStore.load()
        didLoadPersistedAssociations = true
    }

    private func updatePersistedAssociationIfNeeded(from session: SessionState) -> Bool {
        ensurePersistedAssociationsLoaded()
        let key = SessionAssociationStore.cacheKey(provider: session.provider, sessionId: session.sessionId)
        let updatedAssociation = PersistedSessionAssociation(session: session)
        guard persistedAssociations[key] != updatedAssociation else {
            return false
        }

        persistedAssociations[key] = updatedAssociation
        return true
    }

    private func scheduleAssociationSave() {
        let snapshot = persistedAssociations
        pendingAssociationSave?.cancel()
        pendingAssociationSave = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            SessionAssociationStore.save(snapshot)
        }
    }

    private func removePersistedAssociation(provider: SessionProvider, sessionId: String) -> Bool {
        ensurePersistedAssociationsLoaded()
        let key = SessionAssociationStore.cacheKey(provider: provider, sessionId: sessionId)
        return persistedAssociations.removeValue(forKey: key) != nil
    }

    private func resolveCodexSessionAlias(_ sessionId: String) -> String {
        var resolved = sessionId
        var visited: Set<String> = []

        while let next = codexSessionAliases[resolved], visited.insert(resolved).inserted {
            resolved = next
        }

        return resolved
    }

    private func aliasCodexSession(_ previousSessionId: String, to currentSessionId: String) {
        guard previousSessionId != currentSessionId else { return }

        for (alias, target) in codexSessionAliases where target == previousSessionId {
            codexSessionAliases[alias] = currentSessionId
        }
        codexSessionAliases[previousSessionId] = currentSessionId
    }

    private func clearCodexSessionAliases(for sessionId: String) {
        codexSessionAliases.removeValue(forKey: sessionId)
        codexSessionAliases = codexSessionAliases.filter { $0.value != sessionId }
    }

    private func resolveOrAdoptCodexHookSession(_ event: HookEvent) -> String {
        let resolvedSessionId = resolveCodexSessionAlias(event.sessionId)
        guard resolvedSessionId == event.sessionId else {
            return resolvedSessionId
        }
        guard !sessions.keys.contains(event.sessionId) else {
            return event.sessionId
        }

        let candidateCwd = event.cwd.isEmpty ? "/" : event.cwd
        let candidate = SessionState(
            sessionId: event.sessionId,
            cwd: candidateCwd,
            projectName: Self.projectName(for: candidateCwd, fallback: "Codex"),
            provider: .codex,
            clientInfo: normalizedCodexClientInfo(
                restored: nil,
                incoming: event.clientInfo,
                sessionId: event.sessionId
            ),
            ingress: .hookBridge,
            latestHookMessage: Self.normalizedHookMessage(event.message),
            phase: event.sessionPhase,
            lastActivity: Date()
        )

        guard candidate.isLikelyTransientCodexContinuationPlaceholder else {
            return event.sessionId
        }

        guard let existingSession = sessions.values
            .filter({
                candidate.shouldRebindToExistingCodexThread(
                    comparedTo: $0,
                    maximumRecencyGap: codexContinuationMergeWindow
                )
            })
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first else {
            return event.sessionId
        }

        aliasCodexSession(event.sessionId, to: existingSession.sessionId)
        Self.logger.notice(
            "Rebound Codex hook placeholder hookSession=\(event.sessionId, privacy: .public) existingSession=\(existingSession.sessionId, privacy: .public) cwd=\(candidateCwd, privacy: .public)"
        )
        return existingSession.sessionId
    }

    private func resolveOrAdoptCodexSession(
        incomingSessionId: String,
        name: String?,
        preview: String?,
        cwd: String?,
        phase: SessionPhase,
        clientInfo: SessionClientInfo?,
        conversationInfo: ConversationInfo,
        activityAt: Date,
        ingress: SessionIngress
    ) -> String {
        let resolvedIncomingId = resolveCodexSessionAlias(incomingSessionId)
        guard resolvedIncomingId == incomingSessionId else {
            return resolvedIncomingId
        }
        guard !sessions.keys.contains(incomingSessionId) else {
            return incomingSessionId
        }
        guard ingress == .codexAppServer else {
            return incomingSessionId
        }

        let candidateCwd: String = {
            let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "/" : trimmed
        }()
        let candidateClientInfo = normalizedCodexClientInfo(
            restored: nil,
            incoming: clientInfo,
            sessionId: incomingSessionId
        )
        let candidate = SessionState(
            sessionId: incomingSessionId,
            cwd: candidateCwd,
            projectName: Self.projectName(for: candidateCwd, fallback: name ?? "Codex"),
            provider: .codex,
            clientInfo: candidateClientInfo,
            ingress: ingress,
            sessionName: name,
            previewText: preview,
            phase: phase,
            conversationInfo: conversationInfo,
            lastActivity: activityAt
        )

        guard let existingSession = sessions.values
            .filter({
                candidate.shouldRebindToExistingCodexThread(
                    comparedTo: $0,
                    maximumRecencyGap: codexContinuationMergeWindow
                )
            })
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first else {
            return incomingSessionId
        }

        migrateCodexSessionState(from: existingSession.sessionId, to: incomingSessionId)
        aliasCodexSession(existingSession.sessionId, to: incomingSessionId)
        Self.logger.notice(
            "Rebound Codex continuation oldSession=\(existingSession.sessionId, privacy: .public) newThread=\(incomingSessionId, privacy: .public) cwd=\(candidateCwd, privacy: .public)"
        )
        return incomingSessionId
    }

    private func migrateCodexSessionState(from previousSessionId: String, to currentSessionId: String) {
        guard previousSessionId != currentSessionId,
              let previousSession = sessions.removeValue(forKey: previousSessionId),
              !sessions.keys.contains(currentSessionId) else {
            return
        }

        cancelPendingSync(sessionId: previousSessionId)
        cancelPendingCodexPlaceholderPrune(sessionId: previousSessionId)
        cancelPendingQoderConversationPoll(sessionId: previousSessionId)

        let migratedSession = SessionState(
            sessionId: currentSessionId,
            cwd: previousSession.cwd,
            projectName: previousSession.projectName,
            provider: previousSession.provider,
            clientInfo: previousSession.clientInfo,
            ingress: previousSession.ingress,
            sessionName: previousSession.sessionName,
            previewText: previousSession.previewText,
            latestHookMessage: previousSession.latestHookMessage,
            intervention: previousSession.intervention,
            pid: previousSession.pid,
            tty: previousSession.tty,
            isInTmux: previousSession.isInTmux,
            phase: previousSession.phase,
            chatItems: previousSession.chatItems,
            toolTracker: previousSession.toolTracker,
            completedErrorToolIDs: previousSession.completedErrorToolIDs,
            subagentState: previousSession.subagentState,
            conversationInfo: previousSession.conversationInfo,
            needsClearReconciliation: previousSession.needsClearReconciliation,
            lastActivity: previousSession.lastActivity,
            createdAt: previousSession.createdAt
        )

        sessions[currentSessionId] = migratedSession
        _ = removePersistedAssociation(provider: .codex, sessionId: previousSessionId)
    }

    private func runtimeClientInfo(for session: SessionState, tree: [Int: ProcessInfo]) async -> SessionClientInfo? {
        let resolvedTTY = session.tty?.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminalPid =
            resolvedTTY.flatMap { ProcessTreeBuilder.shared.findTerminalPid(forTTY: $0, tree: tree) }
            ?? session.pid.flatMap { ProcessTreeBuilder.shared.findTerminalPid(forProcess: $0, tree: tree) }

        guard let terminalPid,
              let appIdentity = await runningApplicationIdentity(forProcess: terminalPid, tree: tree) else {
            return nil
        }

        let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: appIdentity.bundleIdentifier)
        let appName = appIdentity.name
        let workspaceLaunchURL = SessionClientInfo.appLaunchURL(
            bundleIdentifier: normalizedBundleIdentifier,
            workspacePath: session.cwd
        )

        var runtimeInfo = SessionClientInfo(
            kind: session.clientInfo.kind,
            launchURL: workspaceLaunchURL,
            originator: appName,
            threadSource: TerminalAppRegistry.isIDEBundle(normalizedBundleIdentifier)
                ? (session.clientInfo.threadSource ?? "ide-terminal")
                : session.clientInfo.threadSource,
            terminalBundleIdentifier: normalizedBundleIdentifier
        )

        if session.provider == .codex,
           isStandaloneCodexHost(bundleIdentifier: normalizedBundleIdentifier, name: appName) {
            runtimeInfo = runtimeInfo.merged(with: SessionClientInfo(
                kind: .codexApp,
                name: appName,
                bundleIdentifier: normalizedBundleIdentifier,
                launchURL: SessionClientInfo.appLaunchURL(
                    bundleIdentifier: normalizedBundleIdentifier,
                    sessionId: session.sessionId,
                    workspacePath: session.cwd
                ),
                origin: session.clientInfo.origin ?? "desktop",
                originator: appName
            ))
        }

        return runtimeInfo
    }

    private func normalizedClientInfo(
        _ clientInfo: SessionClientInfo,
        provider: SessionProvider,
        sessionId: String
    ) -> SessionClientInfo {
        switch provider {
        case .claude:
            return clientInfo.normalizedForClaudeRouting()
        case .codex:
            return clientInfo.normalizedForCodexRouting(sessionId: sessionId)
        }
    }

    private func normalizedCodexClientInfo(
        restored: SessionClientInfo?,
        incoming: SessionClientInfo?,
        sessionId: String
    ) -> SessionClientInfo {
        let normalizedRestored = restored?.normalizedForCodexRouting(sessionId: sessionId)
        let normalizedIncoming = incoming?.normalizedForCodexRouting(sessionId: sessionId)
        let base: SessionClientInfo

        if normalizedIncoming?.kind == .codexCLI || normalizedRestored?.kind == .codexCLI {
            base = SessionClientInfo.codexCLI()
        } else {
            base = SessionClientInfo.codexApp(threadId: sessionId)
        }

        return base
            .merged(with: normalizedRestored ?? base)
            .merged(with: normalizedIncoming ?? base)
            .normalizedForCodexRouting(sessionId: sessionId)
    }

    private func runningApplicationIdentity(
        forProcess pid: Int,
        tree: [Int: ProcessInfo]
    ) async -> (bundleIdentifier: String, name: String)? {
        var currentPid = pid
        var depth = 0

        while currentPid > 1 && depth < 20 {
            let lookupPid = currentPid
            if let identity = await MainActor.run(resultType: (bundleIdentifier: String, name: String)?.self, body: {
                guard let app = NSRunningApplication(processIdentifier: pid_t(lookupPid)),
                      let bundleIdentifier = app.bundleIdentifier else {
                    return nil
                }

                let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: bundleIdentifier)
                let hostName = NSRunningApplication.runningApplications(withBundleIdentifier: normalizedBundleIdentifier)
                    .first?
                    .localizedName
                return (
                    bundleIdentifier: normalizedBundleIdentifier,
                    name: hostName ?? app.localizedName ?? bundleIdentifier
                )
            }) {
                return identity
            }

            guard let processInfo = tree[currentPid] else { break }
            currentPid = processInfo.ppid
            depth += 1
        }

        return nil
    }

    private func isStandaloneCodexHost(bundleIdentifier: String, name: String) -> Bool {
        if TerminalAppRegistry.isTerminalBundle(bundleIdentifier) || TerminalAppRegistry.isIDEBundle(bundleIdentifier) {
            return false
        }

        let loweredBundle = bundleIdentifier.lowercased()
        let loweredName = name.lowercased()
        return loweredBundle.contains("codex") || loweredName.contains("codex")
    }

    private func shouldIgnoreCodexHookEvent(_ event: HookEvent, existingSession: SessionState?) -> Bool {
        guard event.provider == .codex else { return false }
        guard case .none = existingSession else { return false }
        guard event.clientInfo.sessionFilePath?.isEmpty != false else { return false }
        guard !event.expectsResponse else { return false }
        guard case .none = event.intervention else { return false }

        return Self.normalizedHookMessage(event.message) == nil
    }

    private func updateCodexPlaceholderPrune(for session: SessionState) {
        if shouldPruneCodexHookPlaceholder(session) {
            scheduleCodexPlaceholderPrune(sessionId: session.sessionId)
        } else {
            cancelPendingCodexPlaceholderPrune(sessionId: session.sessionId)
        }
    }

    private func scheduleCodexPlaceholderPrune(sessionId: String) {
        cancelPendingCodexPlaceholderPrune(sessionId: sessionId)
        guard let delayNs = codexPlaceholderPruneDelayNs(for: sessions[sessionId]) else {
            return
        }
        pendingCodexPlaceholderPrunes[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            await self?.pruneCodexHookPlaceholderIfNeeded(sessionId: sessionId)
        }
    }

    private func cancelPendingCodexPlaceholderPrune(sessionId: String) {
        pendingCodexPlaceholderPrunes[sessionId]?.cancel()
        pendingCodexPlaceholderPrunes.removeValue(forKey: sessionId)
    }

    private func pruneCodexHookPlaceholderIfNeeded(sessionId: String) async {
        pendingCodexPlaceholderPrunes.removeValue(forKey: sessionId)
        guard let session = sessions[sessionId], shouldPruneCodexHookPlaceholder(session) else {
            return
        }

        Self.logger.notice(
            "Pruning stale Codex placeholder session=\(sessionId, privacy: .public) phase=\(String(describing: session.phase), privacy: .public)"
        )
        sessions.removeValue(forKey: sessionId)
        clearCodexSessionAliases(for: sessionId)
        cancelPendingSync(sessionId: sessionId)
        publishState()
    }

    private func pruneExpiredCodexHookPlaceholders(referenceDate: Date) -> [String] {
        let expiredSessionIDs = sessions.values.compactMap { session -> String? in
            guard shouldPruneCodexHookPlaceholder(session) else { return nil }
            guard isCodexHookPlaceholderExpired(session, referenceDate: referenceDate) else { return nil }
            return session.sessionId
        }

        guard !expiredSessionIDs.isEmpty else { return [] }
        for sessionId in expiredSessionIDs {
            Self.logger.notice(
                "Pruning expired Codex placeholder during publish session=\(sessionId, privacy: .public)"
            )
            sessions.removeValue(forKey: sessionId)
            clearCodexSessionAliases(for: sessionId)
            cancelPendingSync(sessionId: sessionId)
            cancelPendingCodexPlaceholderPrune(sessionId: sessionId)
        }
        return expiredSessionIDs
    }

    private func shouldPruneCodexHookPlaceholder(_ session: SessionState) -> Bool {
        codexPlaceholderPruneDelayNs(for: session) != nil
    }

    private func isCodexHookPlaceholderExpired(_ session: SessionState, referenceDate: Date) -> Bool {
        let anchor = max(session.lastActivity, session.createdAt)
        guard let delayNs = codexPlaceholderPruneDelayNs(for: session) else { return false }
        let expirationInterval = TimeInterval(delayNs) / 1_000_000_000
        return referenceDate.timeIntervalSince(anchor) >= expirationInterval
    }

    private func codexPlaceholderPruneDelayNs(for session: SessionState?) -> UInt64? {
        guard let session, session.provider == .codex, isLikelyEmptyCodexPlaceholder(session) else {
            return nil
        }

        switch session.ingress {
        case .hookBridge:
            return codexHookPlaceholderPruneDelayNs
        case .codexAppServer:
            return codexAppServerPlaceholderPruneDelayNs
        }
    }

    private func isLikelyEmptyCodexPlaceholder(_ session: SessionState) -> Bool {
        guard session.provider == .codex else { return false }
        guard session.phase == .idle || session.phase == .ended || session.phase == .processing else { return false }
        return session.isLikelyEmptyCodexPlaceholderForUI
            || session.isLikelyTransientCodexContinuationPlaceholder
    }
}
