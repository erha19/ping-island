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
        let effectiveDisplayTitle: String
        let sessionName: String?
        let previewText: String?
        let lastMessage: String?
        let clientKind: String
        let clientName: String?
        let sessionFilePath: String?
        let presentationMode: String
        let usesTitleOnlySubagentPresentation: Bool
        let linkedParentSessionId: String?
        let linkedSubagentDisplayTitle: String?
        let codexSubagentLevel: Int?
        let codexSubagentLabel: String?
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
    private var pendingOpenClawConversationPolls: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var codexSessionAliases: [String: String] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000
    private let codexHookPlaceholderPruneDelayNs: UInt64 = 10_000_000_000
    private let codexAppServerPlaceholderPruneDelayNs: UInt64 = 60_000_000_000
    private let codexContinuationMergeWindow: TimeInterval = 10 * 60
    private let apparentIdleProcessingGraceWindow: TimeInterval = 5 * 60
    private let qoderConversationPollIntervalNs: UInt64 = 250_000_000
    private let qoderConversationPollTimeoutNs: UInt64 = 120_000_000_000
    private let qoderSubagentAssociationWindow: TimeInterval = 2 * 60
    private let openClawConversationPollIntervalNs: UInt64 = 1_000_000_000
    private let openClawConversationPollTimeoutNs: UInt64 = 30_000_000_000

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
        if event.shouldEmitProcessingLog {
            if let sessionPrefix = event.processingLogSessionPrefix {
                Self.logger.debug(
                    "Processing event=\(event.processingLogName, privacy: .public) session=\(sessionPrefix, privacy: .public)"
                )
            } else {
                Self.logger.debug("Processing event=\(event.processingLogName, privacy: .public)")
            }
        }

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .runtimeSessionStarted(let handle):
            processNativeRuntimeSessionStarted(handle)

        case .runtimeSessionStopped(let sessionId, _):
            await processSessionEnd(sessionId: sessionId)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionAutoApprovalChanged(let sessionId, let isEnabled):
            processPermissionAutoApprovalChanged(sessionId: sessionId, isEnabled: isEnabled)

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

    private func processNativeRuntimeSessionStarted(_ handle: SessionRuntimeHandle) {
        let restoredAssociation = persistedAssociation(for: handle.provider, sessionId: handle.sessionID)
        let projectName = restoredAssociation?.projectName
            ?? Self.projectName(for: handle.cwd, fallback: handle.provider.displayName)

        let runtimeClientInfo: SessionClientInfo
        switch handle.provider {
        case .claude:
            runtimeClientInfo = SessionClientInfo(
                kind: .claudeCode,
                name: "Claude Native",
                origin: "native-runtime",
                sessionFilePath: handle.sessionFilePath,
                processName: "claude"
            )
        case .codex:
            runtimeClientInfo = SessionClientInfo(
                kind: .codexCLI,
                name: "Codex Native",
                origin: "native-runtime",
                sessionFilePath: handle.sessionFilePath,
                processName: "codex"
            )
        case .copilot:
            runtimeClientInfo = SessionClientInfo.default(for: .copilot)
        }

        let resolvedClientInfo = normalizedClientInfo(
            (restoredAssociation?.clientInfo ?? runtimeClientInfo).merged(with: runtimeClientInfo),
            provider: handle.provider,
            sessionId: handle.sessionID
        )

        let existing = sessions[handle.sessionID]
        let session = SessionState(
            sessionId: handle.sessionID,
            cwd: handle.cwd,
            projectName: projectName,
            provider: handle.provider,
            clientInfo: resolvedClientInfo,
            ingress: .nativeRuntime,
            sessionName: restoredAssociation?.sessionName ?? existing?.sessionName,
            pid: existing?.pid,
            tty: existing?.tty,
            isInTmux: existing?.isInTmux ?? false,
            autoApprovePermissions: existing?.autoApprovePermissions ?? false,
            phase: existing?.phase == .ended ? .idle : (existing?.phase ?? .idle),
            chatItems: existing?.chatItems ?? [],
            toolTracker: existing?.toolTracker ?? ToolTracker(),
            completedErrorToolIDs: existing?.completedErrorToolIDs ?? [],
            subagentState: existing?.subagentState ?? SubagentState(),
            conversationInfo: existing?.conversationInfo ?? ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            needsClearReconciliation: existing?.needsClearReconciliation ?? false,
            lastActivity: Date(),
            createdAt: existing?.createdAt ?? handle.createdAt
        )

        sessions[handle.sessionID] = session
    }

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
        if shouldIgnoreClaudeAskUserQuestionPermissionRequest(event) {
            Self.logger.notice(
                "Ignoring duplicate Claude AskUserQuestion permission session=\(sessionId, privacy: .public)"
            )
            return
        }
        var session = sessions[sessionId] ?? createSession(from: event)

        // Persist the session before await points so concurrent events (via actor
        // reentrancy) find it instead of creating a duplicate.  This avoids the
        // race where a Stop event runs during a Notification's await, ends its own
        // fresh copy, and then the Notification resumes against an already-ended
        // session.
        if sessions[sessionId] == nil {
            sessions[sessionId] = session
        }

        let tree = (event.pid != nil || event.tty != nil) ? ProcessTreeBuilder.shared.buildTree() : [:]

        session.provider = event.provider
        session.clientInfo = session.clientInfo.merged(with: event.clientInfo)
        session.clientInfo = normalizedClientInfo(session.clientInfo, provider: event.provider, sessionId: sessionId)
        session.ingress = event.ingress
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
        if let enrichedGhosttyClientInfo = await enrichedGhosttyClientInfoIfNeeded(
            current: session.clientInfo,
            event: event,
            workspacePath: session.cwd
        ) {
            session.clientInfo = normalizedClientInfo(
                session.clientInfo.merged(with: enrichedGhosttyClientInfo),
                provider: event.provider,
                sessionId: sessionId
            )
        }

        // After the await points another event may have mutated the persisted
        // copy (actor reentrancy).  Merge the enriched client info into the
        // latest snapshot so we don't silently discard phase / chatItem changes
        // made by the concurrent event.
        if let latest = sessions[sessionId], latest.lastActivity > session.lastActivity {
            session = latest
            // Re-apply enrichment
            session.clientInfo = session.clientInfo.merged(with: event.clientInfo)
            session.clientInfo = normalizedClientInfo(session.clientInfo, provider: event.provider, sessionId: sessionId)
        }

        let previousLastActivity = session.lastActivity
        session.lastActivity = Date()
        if let hookMessage = Self.normalizedHookMessage(event.message) {
            if shouldCaptureHookMessage(hookMessage, for: event, session: session) {
                session.latestHookMessage = hookMessage
            }
        }

        // For hook-only clients without JSONL (e.g. Hermes), build chat history
        // directly from hook events so users can see conversation content.
        if session.clientInfo.isHermesClient {
            appendHermesHookChatItem(event: event, session: &session)
        }

        let shouldPreserveEndedStopForAnsweredQuestion =
            event.status == "ended"
            && event.event == "Stop"
            && session.intervention?.awaitsExternalContinuation == true
            && session.clientInfo.prefersAnsweredQuestionFollowupAction

        if event.status == "ended", !shouldPreserveEndedStopForAnsweredQuestion {
            markSessionEnded(&session)
            sessions[sessionId] = session
            syncLinkedQoderChildSessions(for: session)
            if session.clientInfo.isQwenCodeClient {
                Self.logger.info(
                    "Qwen session ended session=\(sessionId, privacy: .public) phase=\(session.phase.description, privacy: .public) notification=\((event.notificationType ?? "").prefix(40), privacy: .public) latestHook=\((session.latestHookMessage ?? "").prefix(120), privacy: .public) conversationLast=\((session.conversationInfo.lastMessage ?? "").prefix(120), privacy: .public)"
                )
            }
            if session.clientInfo.isHermesClient {
                Self.logger.info(
                    "Hermes session ended session=\(sessionId, privacy: .public) phase=\(session.phase.description, privacy: .public) message=\((session.latestHookMessage ?? "").prefix(120), privacy: .public)"
                )
            }
            cancelPendingCodexPlaceholderPrune(sessionId: sessionId)
            cancelPendingQoderConversationPoll(sessionId: sessionId)
            scheduleFinalSessionSync(for: session)
            return
        }

        let newPhase: SessionPhase = shouldPreserveEndedStopForAnsweredQuestion
            ? .waitingForInput
            : event.determinePhase()
        let intervention = event.intervention
        let shouldPreserveQwenQuestionIntervention = shouldPreserveQwenQuestionIntervention(
            for: event,
            newPhase: newPhase,
            currentIntervention: session.intervention
        )
        let preservedPendingApproval = preservedPendingApprovalContext(
            for: event,
            session: session,
            newPhase: newPhase
        )
        let shouldSuppressPendingApprovalCompletion = shouldSuppressPendingApprovalCompletion(
            for: event,
            session: session
        )

        if let preservedPendingApproval {
            Self.logger.debug(
                "Preserving waitingForApproval for \(sessionId.prefix(8), privacy: .public) on \(event.event, privacy: .public)"
            )
            session.phase = .waitingForApproval(preservedPendingApproval)
        } else if shouldPreserveActivePhaseDuringApparentIdle(
            session: session,
            incomingPhase: newPhase,
            referenceDate: Date(),
            previousLastActivity: previousLastActivity
        ) {
            session.lastActivity = previousLastActivity
        } else if let resumedPhase = resumedPhaseForFreshHookActivity(
            currentPhase: session.phase,
            incomingPhase: newPhase,
            event: event
        ) {
            session.phase = resumedPhase
        } else if shouldPreserveExistingQwenApprovalPhase(event: event, session: session, newPhase: newPhase) {
            Self.logger.debug(
                "Preserving existing Qwen approval phase over notification for \(sessionId.prefix(8), privacy: .public)"
            )
        } else if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug(
                "Invalid transition current=\(session.phase.description, privacy: .public) next=\(newPhase.description, privacy: .public), ignoring"
            )
        }

        if let intervention {
            if session.clientInfo.brand == .qoder, intervention.kind == .question {
                session.intervention = mergedQoderQuestionIntervention(
                    current: session.intervention,
                    proposed: intervention
                )
            } else if shouldPreserveExistingQwenIntervention(
                for: event,
                currentIntervention: session.intervention
            ) {
                // Notification-derived approval should not override existing intervention
            } else {
                session.intervention = intervention
            }

            if intervention.kind == .question {
                session.phase = .waitingForInput
            }
        } else if shouldPreserveQwenQuestionIntervention {
            session.phase = .waitingForInput
        } else if shouldClearIntervention(for: event, newPhase: newPhase, currentIntervention: session.intervention) {
            session.intervention = nil
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(
            event: event,
            session: &session,
            preservingPendingApproval: shouldSuppressPendingApprovalCompletion
        )
        processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        associateQoderChildSessionIfNeeded(sessionId: sessionId, event: event, session: &session)

        sessions[sessionId] = session
        syncLinkedQoderChildSessions(for: session)
        if session.clientInfo.isQwenCodeClient {
            Self.logger.info(
                "Qwen session updated session=\(sessionId, privacy: .public) event=\(event.event, privacy: .public) status=\(event.status, privacy: .public) notification=\((event.notificationType ?? "").prefix(40), privacy: .public) phase=\(session.phase.description, privacy: .public) latestHook=\((session.latestHookMessage ?? "").prefix(120), privacy: .public) conversationLast=\((session.conversationInfo.lastMessage ?? "").prefix(120), privacy: .public)"
            )
        }
        if session.clientInfo.isHermesClient {
            Self.logger.info(
                "Hermes session updated session=\(sessionId, privacy: .public) event=\(event.event, privacy: .public) phase=\(session.phase.description, privacy: .public) message=\((session.latestHookMessage ?? "").prefix(120), privacy: .public)"
            )
        }
        updateCodexPlaceholderPrune(for: session)
        updateQoderConversationPoll(for: session, event: event)
        updateOpenClawConversationPoll(for: session, event: event)

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
            ingress: event.ingress,
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

    private func shouldCaptureHookMessage(
        _ hookMessage: String,
        for event: HookEvent,
        session: SessionState
    ) -> Bool {
        guard event.clientInfo.isQwenCodeClient else { return true }

        // PermissionRequest messages: always skip to preserve earlier assistant messages
        if event.event == "PermissionRequest" {
            Self.logger.info(
                "Skipping Qwen PermissionRequest hook message session=\(event.sessionId, privacy: .public) incoming=\(hookMessage.prefix(120), privacy: .public) existing=\((session.latestHookMessage ?? "").prefix(120), privacy: .public)"
            )
            return false
        }

        // Notification permission_prompt: allow when creating a new approval state,
        // skip when there is already an active approval (PermissionRequest arrived first).
        if event.notificationType == "permission_prompt" {
            if session.phase.isWaitingForApproval {
                Self.logger.info(
                    "Skipping Qwen permission_prompt hook message (already in approval) session=\(event.sessionId, privacy: .public) incoming=\(hookMessage.prefix(120), privacy: .public)"
                )
                return false
            }
            return true
        }

        return true
    }

    /// Build chat history items from Hermes hook events so the conversation is
    /// visible in the session detail view even without a JSONL file.
    private func appendHermesHookChatItem(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "UserPromptSubmit":
            guard let message = Self.normalizedHookMessage(event.message), !message.isEmpty else { return }
            let id = "hermes-user-\(session.chatItems.count)-\(Int(Date().timeIntervalSince1970 * 1000))"
            session.chatItems.append(ChatHistoryItem(
                id: id,
                type: .user(message),
                timestamp: Date()
            ))
            // Capture as first user message for session display title.
            if session.conversationInfo.firstUserMessage == nil {
                session.conversationInfo = ConversationInfo(
                    summary: session.conversationInfo.summary,
                    lastMessage: session.conversationInfo.lastMessage,
                    lastMessageRole: session.conversationInfo.lastMessageRole,
                    lastToolName: session.conversationInfo.lastToolName,
                    firstUserMessage: message,
                    lastUserMessageDate: Date()
                )
            }
            Self.logger.debug(
                "Hermes chat item appended type=user session=\(event.sessionId.prefix(8), privacy: .public) length=\(message.count)"
            )

        case "Notification":
            guard event.notificationType == "assistant_message" else { return }
            guard let message = Self.normalizedHookMessage(event.message), !message.isEmpty else { return }
            let id = "hermes-assistant-\(session.chatItems.count)-\(Int(Date().timeIntervalSince1970 * 1000))"
            session.chatItems.append(ChatHistoryItem(
                id: id,
                type: .assistant(message),
                timestamp: Date()
            ))
            // Keep conversationInfo.lastMessage in sync so the UI
            // can show the latest assistant reply everywhere.
            session.conversationInfo = ConversationInfo(
                summary: session.conversationInfo.summary,
                lastMessage: message,
                lastMessageRole: "assistant",
                lastToolName: session.conversationInfo.lastToolName,
                firstUserMessage: session.conversationInfo.firstUserMessage,
                lastUserMessageDate: session.conversationInfo.lastUserMessageDate
            )
            Self.logger.debug(
                "Hermes chat item appended type=assistant session=\(event.sessionId.prefix(8), privacy: .public) length=\(message.count)"
            )

        default:
            break  // Tool events are handled by processToolTracking.
        }
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

    private func shouldSuppressPendingApprovalCompletion(for event: HookEvent, session: SessionState) -> Bool {
        guard event.event == "PostToolUse",
              let activePermission = session.activePermission,
              let toolUseId = event.toolUseId
        else {
            return false
        }

        return activePermission.toolUseId == toolUseId
    }

    private func preservedPendingApprovalContext(
        for event: HookEvent,
        session: SessionState,
        newPhase: SessionPhase
    ) -> PermissionContext? {
        guard !newPhase.isWaitingForApproval,
              event.event != "PermissionRequest",
              event.event != "SessionEnd",
              event.event != "Stop",
              event.status != "ended",
              !event.isAskUserQuestionRequest,
              case .none = event.intervention else {
            return nil
        }

        if let activePermission = session.activePermission {
            return activePermission
        }

        return pendingApprovalContext(in: session, preferring: event.toolUseId)
    }

    private func pendingApprovalContext(
        in session: SessionState,
        preferring toolUseId: String?
    ) -> PermissionContext? {
        if let toolUseId,
           let preferredMatch = pendingApprovalItem(in: session, matching: toolUseId) {
            return preferredMatch
        }

        return pendingApprovalItem(in: session)
    }

    private func pendingApprovalItem(
        in session: SessionState,
        matching toolUseId: String? = nil
    ) -> PermissionContext? {
        let pendingTool = session.chatItems
            .reversed()
            .first { item in
                guard case .toolCall(let tool) = item.type,
                      tool.status == .waitingForApproval else {
                    return false
                }
                guard let toolUseId else {
                    return true
                }
                return item.id == toolUseId
            }

        guard let pendingTool,
              case .toolCall(let tool) = pendingTool.type else {
            return nil
        }

        return PermissionContext(
            toolUseId: pendingTool.id,
            toolName: tool.name,
            toolInput: nil,
            receivedAt: pendingTool.timestamp
        )
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

    private func associateQoderChildSessionIfNeeded(
        sessionId: String,
        event: HookEvent,
        session: inout SessionState
    ) {
        guard session.clientInfo.brand == .qoder else { return }
        guard !session.usesTitleOnlySubagentPresentation else { return }
        guard event.event != "Stop", event.event != "SessionEnd" else { return }
        guard (event.tool?.caseInsensitiveCompare("Agent") ?? .orderedDescending) != .orderedSame else { return }
        guard let parent = qoderParentCandidate(for: sessionId, cwd: session.cwd) else { return }

        session.linkedParentSessionId = parent.sessionId
        session.linkedSubagentDisplayTitle = qoderSubagentDisplayTitle(from: parent)
            ?? session.linkedSubagentDisplayTitle

        Self.logger.notice(
            "Linked Qoder child session child=\(sessionId, privacy: .public) parent=\(parent.sessionId, privacy: .public)"
        )
    }

    private func qoderParentCandidate(for childSessionId: String, cwd: String) -> SessionState? {
        let referenceDate = Date()

        return sessions.values
            .compactMap { session -> (SessionState, Date)? in
                guard session.sessionId != childSessionId else { return nil }
                guard session.clientInfo.brand == .qoder else { return nil }
                guard session.cwd == cwd else { return nil }
                guard session.phase != .ended else { return nil }
                guard !session.usesTitleOnlySubagentPresentation else { return nil }
                guard let agentTimestamp = recentQoderAgentTimestamp(in: session) else { return nil }
                guard referenceDate.timeIntervalSince(agentTimestamp) <= qoderSubagentAssociationWindow else {
                    return nil
                }
                return (session, agentTimestamp)
            }
            .sorted { lhs, rhs in lhs.1 > rhs.1 }
            .first?
            .0
    }

    private func recentQoderAgentTimestamp(in session: SessionState) -> Date? {
        for item in session.chatItems.reversed() {
            guard case .toolCall(let tool) = item.type else { continue }
            guard tool.name.caseInsensitiveCompare("Agent") == .orderedSame else { continue }
            guard tool.status == .running || tool.status == .success else { continue }
            return item.timestamp
        }

        return nil
    }

    private func qoderSubagentDisplayTitle(from parent: SessionState) -> String? {
        for item in parent.chatItems.reversed() {
            guard case .toolCall(let tool) = item.type else { continue }
            guard tool.name.caseInsensitiveCompare("Agent") == .orderedSame else { continue }

            let description = tool.input["description"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let description, !description.isEmpty {
                return "Agent · \(description)"
            }

            return "Agent"
        }

        return nil
    }

    private func refreshQoderFallbackSubagentPresentation(
        for sessionId: String,
        session: inout SessionState
    ) async {
        guard session.clientInfo.brand == .qoder else { return }

        if session.isLinkedSubagentSession {
            session.heuristicSubagentDisplayTitle = nil
            return
        }

        let fallbackPresentation = await ConversationParser.shared.qoderFallbackSubagentPresentation(
            sessionId: sessionId,
            cwd: session.cwd,
            explicitFilePath: session.clientInfo.sessionFilePath
        )
        session.heuristicSubagentDisplayTitle = fallbackPresentation?.displayTitle
    }

    private func syncLinkedQoderChildSessions(for parent: SessionState) {
        guard parent.clientInfo.brand == .qoder else { return }
        guard let mirroredPhase = mirroredPhaseForLinkedQoderChild(parent.phase) else { return }

        for sessionId in sessions.keys {
            guard var child = sessions[sessionId] else { continue }
            guard child.linkedParentSessionId == parent.sessionId else { continue }

            if mirroredPhase == .ended {
                guard child.phase != .ended else { continue }
                markSessionEnded(&child)
                child.lastActivity = max(child.lastActivity, parent.lastActivity)
                sessions[sessionId] = child
                continue
            }

            guard child.phase != mirroredPhase else { continue }
            guard child.phase.canTransition(to: mirroredPhase) else { continue }

            child.phase = mirroredPhase
            child.lastActivity = max(child.lastActivity, parent.lastActivity)
            sessions[sessionId] = child
        }
    }

    private func mirroredPhaseForLinkedQoderChild(_ phase: SessionPhase) -> SessionPhase? {
        switch phase {
        case .processing:
            return nil
        case .idle:
            return .idle
        case .compacting:
            return .compacting
        case .waitingForInput:
            return .waitingForInput
        case .waitingForApproval(let context):
            return .waitingForApproval(context)
        case .ended:
            return .ended
        }
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionAutoApprovalChanged(sessionId: String, isEnabled: Bool) {
        guard var session = sessions[sessionId] else { return }
        session.autoApprovePermissions = isEnabled
        sessions[sessionId] = session
    }

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

        clearResolvedApprovalIntervention(in: &session, toolUseId: toolUseId)
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
                Self.logger.debug(
                    "Tool \(toolUseId.prefix(12), privacy: .public) completed with status=\(result.status.description, privacy: .public)"
                )
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

        clearResolvedApprovalIntervention(in: &session, toolUseId: toolUseId)
        sessions[sessionId] = session
    }

    private func clearResolvedApprovalIntervention(in session: inout SessionState, toolUseId: String) {
        guard let intervention = session.intervention,
              intervention.kind == .approval,
              intervention.matchesResolvedToolUseId(toolUseId) else {
            return
        }

        session.intervention = nil
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

        clearResolvedApprovalIntervention(in: &session, toolUseId: toolUseId)
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
           session.clientInfo.prefersAnsweredQuestionFollowupAction {
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

        if !payload.messages.isEmpty {
            session.lastActivity = Date()
            let shouldResumeEndedSession = payload.isIncremental
                && payload.messages.contains(where: { $0.role == .user })
            promoteSessionForTranscriptActivity(
                &session,
                allowEndedResume: shouldResumeEndedSession
            )
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
        applyClaudeTranscriptQuestionFallback(to: &session)
        await refreshQoderFallbackSubagentPresentation(for: payload.sessionId, session: &session)

        if payload.isIncremental,
           let continuationAnsweredAt = session.intervention?.externalContinuationAnsweredAt,
           session.intervention?.awaitsExternalContinuation == true,
           session.clientInfo.retainsAnsweredQuestionFollowupActionOnTranscriptUpdates == false,
           payload.messages.contains(where: { $0.timestamp >= continuationAnsweredAt }) {
            session.intervention = nil
            if session.phase == .waitingForInput {
                session.phase = .processing
            }
        }

        sessions[payload.sessionId] = session
        publishState()

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Transcript updates are the strongest signal that a previously dormant session
    /// has resumed doing work. Promote recoverable idle/waiting states back into the
    /// active lane immediately so the primary list and hover dashboard react without
    /// waiting for a later hook heartbeat.
    private func promoteSessionForTranscriptActivity(
        _ session: inout SessionState,
        allowEndedResume: Bool = false
    ) {
        if session.phase == .ended {
            guard allowEndedResume else { return }
            session.phase = .processing
            return
        }
        guard !session.phase.isActive else { return }
        guard !session.needsApprovalResponse else { return }
        guard session.intervention == nil else { return }

        switch session.phase {
        case .idle, .waitingForInput:
            if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
        case .processing, .compacting, .waitingForApproval, .ended:
            break
        }
    }

    private func resumedPhaseForFreshHookActivity(
        currentPhase: SessionPhase,
        incomingPhase: SessionPhase,
        event: HookEvent
    ) -> SessionPhase? {
        guard currentPhase == .ended else { return nil }
        guard event.event != "Stop", event.event != "SessionEnd", event.status != "ended" else {
            return nil
        }

        if incomingPhase.isActive || incomingPhase.needsAttention {
            return incomingPhase
        }

        if event.event == "UserPromptSubmit" {
            return .processing
        }

        return nil
    }

    private func shouldPreserveActivePhaseDuringApparentIdle(
        session: SessionState,
        incomingPhase: SessionPhase,
        referenceDate: Date,
        previousLastActivity: Date?
    ) -> Bool {
        guard session.phase.isActive else { return false }
        guard incomingPhase == .idle else { return false }

        if sessionHasLiveExecutionEvidence(session) {
            return true
        }

        guard let previousLastActivity else { return false }
        return referenceDate.timeIntervalSince(previousLastActivity) < apparentIdleProcessingGraceWindow
    }

    private func sessionHasLiveExecutionEvidence(_ session: SessionState) -> Bool {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .thinking:
                return true
            case .toolCall(let tool):
                return tool.status == .running
            case .assistant, .user, .interrupted:
                return false
            }
        }

        return false
    }

    private func mergedLastActivity(
        existing currentValue: Date?,
        incoming newValue: Date
    ) -> Date {
        guard let currentValue else { return newValue }
        return max(currentValue, newValue)
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
           event.clientInfo.prefersAnsweredQuestionFollowupAction {
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

    private func shouldPreserveQwenQuestionIntervention(
        for event: HookEvent,
        newPhase: SessionPhase,
        currentIntervention: SessionIntervention?
    ) -> Bool {
        guard event.clientInfo.isQwenCodeClient,
              event.event == "Notification",
              event.notificationType == "permission_prompt",
              currentIntervention?.kind == .question,
              newPhase != .waitingForInput else {
            return false
        }

        Self.logger.info(
            "Preserving Qwen question intervention session=\(event.sessionId, privacy: .public) event=\(event.event, privacy: .public) notification=\((event.notificationType ?? "").prefix(40), privacy: .public)"
        )
        return true
    }

    /// Prevent a Notification-derived approval from overriding an existing
    /// intervention (question or real PermissionRequest approval).
    private func shouldPreserveExistingQwenIntervention(
        for event: HookEvent,
        currentIntervention: SessionIntervention?
    ) -> Bool {
        guard event.clientInfo.isQwenCodeClient,
              event.event == "Notification",
              event.notificationType == "permission_prompt",
              currentIntervention != nil else {
            return false
        }

        Self.logger.info(
            "Preserving existing Qwen intervention over notification approval session=\(event.sessionId, privacy: .public)"
        )
        return true
    }

    /// Prevent a Notification-derived waitingForApproval from overwriting an
    /// existing waitingForApproval that came from a real PermissionRequest.
    private func shouldPreserveExistingQwenApprovalPhase(
        event: HookEvent,
        session: SessionState,
        newPhase: SessionPhase
    ) -> Bool {
        guard event.clientInfo.isQwenCodeClient,
              event.event == "Notification",
              event.notificationType == "permission_prompt",
              session.phase.isWaitingForApproval,
              newPhase.isWaitingForApproval else {
            return false
        }
        return true
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
        syncLinkedQoderChildSessions(for: session)
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
        syncLinkedQoderChildSessions(for: session)
        cancelPendingCodexPlaceholderPrune(sessionId: resolvedSessionId)
        cancelPendingQoderConversationPoll(sessionId: resolvedSessionId)
        scheduleFinalSessionSync(for: session)
    }

    private func archiveSession(sessionId: String) async {
        let resolvedSessionId = resolveCodexSessionAlias(sessionId)
        let linkedChildSessionIDs = sessions.values
            .filter { $0.linkedParentSessionId == resolvedSessionId }
            .map(\.sessionId)
        sessions.removeValue(forKey: resolvedSessionId)
        for childSessionId in linkedChildSessionIDs {
            sessions.removeValue(forKey: childSessionId)
        }
        clearCodexSessionAliases(for: resolvedSessionId)
        cancelPendingSync(sessionId: resolvedSessionId)
        cancelPendingCodexPlaceholderPrune(sessionId: resolvedSessionId)
        cancelPendingQoderConversationPoll(sessionId: resolvedSessionId)
        for childSessionId in linkedChildSessionIDs {
            clearCodexSessionAliases(for: childSessionId)
            cancelPendingSync(sessionId: childSessionId)
            cancelPendingCodexPlaceholderPrune(sessionId: childSessionId)
            cancelPendingQoderConversationPoll(sessionId: childSessionId)
        }
    }

    private func markSessionEnded(_ session: inout SessionState) {
        session.phase = .ended
        session.intervention = nil
        session.autoApprovePermissions = false
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

        if session.provider == .claude, !session.cwd.isEmpty, !session.clientInfo.isHermesClient {
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
        applyClaudeTranscriptQuestionFallback(to: &session)
        await refreshQoderFallbackSubagentPresentation(for: sessionId, session: &session)

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

    private func updateOpenClawConversationPoll(for session: SessionState, event: HookEvent) {
        guard session.clientInfo.isOpenClawGatewayClient else {
            cancelPendingOpenClawConversationPoll(sessionId: session.sessionId)
            return
        }

        if session.phase == .ended || event.status == "ended" {
            cancelPendingOpenClawConversationPoll(sessionId: session.sessionId)
            return
        }

        guard event.event.hasPrefix("message:") else { return }
        scheduleOpenClawConversationPoll(sessionId: session.sessionId)
    }

    private func scheduleOpenClawConversationPoll(sessionId: String) {
        cancelPendingOpenClawConversationPoll(sessionId: sessionId)

        let pollID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }

            let startedAt = Date()
            while !Task.isCancelled {
                guard let session = await self.session(for: sessionId),
                      session.clientInfo.isOpenClawGatewayClient,
                      session.phase != .ended else {
                    break
                }

                await self.scheduleOpenClawConversationSync(
                    sessionId: sessionId,
                    cwd: session.cwd,
                    explicitFilePath: session.clientInfo.sessionFilePath
                )

                if Date().timeIntervalSince(startedAt) * 1_000_000_000 >= Double(self.openClawConversationPollTimeoutNs) {
                    break
                }

                try? await Task.sleep(nanoseconds: self.openClawConversationPollIntervalNs)
            }

            await self.finishOpenClawConversationPoll(sessionId: sessionId, pollID: pollID)
        }

        pendingOpenClawConversationPolls[sessionId] = (id: pollID, task: task)
    }

    private func scheduleOpenClawConversationSync(
        sessionId: String,
        cwd: String,
        explicitFilePath: String?
    ) {
        scheduleFileSync(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: explicitFilePath
        )
    }

    private func cancelPendingOpenClawConversationPoll(sessionId: String) {
        pendingOpenClawConversationPolls[sessionId]?.task.cancel()
        pendingOpenClawConversationPolls.removeValue(forKey: sessionId)
    }

    private func finishOpenClawConversationPoll(sessionId: String, pollID: UUID) {
        guard pendingOpenClawConversationPolls[sessionId]?.id == pollID else { return }
        pendingOpenClawConversationPolls.removeValue(forKey: sessionId)
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

            let appServerSnapshot: CodexThreadSnapshot?
            do {
                appServerSnapshot = try await CodexAppServerMonitor.shared.readThread(
                    threadId: sessionId,
                    includeTurns: true
                )
            } catch {
                appServerSnapshot = nil
                // Fall back to rollout parsing when the app-server is unavailable
                // or the thread hasn't been materialized there yet.
            }

            guard let snapshot = await CodexRolloutParser.shared.parseThread(
                threadId: sessionId,
                fallbackCwd: cwd,
                clientInfo: clientInfo
            ) else {
                return
            }

            if let appServerSnapshot,
               snapshot.intervention == nil,
               snapshot.historyItems.count <= appServerSnapshot.historyItems.count,
               snapshot.updatedAt <= appServerSnapshot.updatedAt {
                return
            }

            await self?.syncCodexThreadSnapshot(snapshot, ingress: .hookBridge)
        }
    }

    // MARK: - State Publishing

    private func publishState() {
        let prunedPlaceholderSessionIDs = pruneExpiredCodexHookPlaceholders(referenceDate: Date())
        let sortedSessions = Array(sessions.values).sorted { lhs, rhs in
            lhs.shouldSortBeforeInQueue(rhs)
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
        guard session.ingress != .remoteBridge else { return }

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
                    effectiveDisplayTitle: session.titleOnlySubagentDisplayTitle,
                    sessionName: session.sessionName,
                    previewText: session.previewText,
                    lastMessage: session.lastMessage,
                    clientKind: session.clientInfo.kind.rawValue,
                    clientName: session.clientInfo.name,
                    sessionFilePath: session.clientInfo.sessionFilePath,
                    presentationMode: session.usesTitleOnlySubagentPresentation ? "titleOnlySubagent" : "standard",
                    usesTitleOnlySubagentPresentation: session.usesTitleOnlySubagentPresentation,
                    linkedParentSessionId: session.linkedParentSessionId,
                    linkedSubagentDisplayTitle: session.linkedSubagentDisplayTitle,
                    codexSubagentLevel: session.codexSubagentLevel,
                    codexSubagentLabel: session.codexSubagentLabel,
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
        let existingLastActivity = sessions[resolvedSessionId]?.lastActivity
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
        let shouldPreserveExternalIntervention = shouldPreserveExternalCodexIntervention(
            current: session.intervention,
            incoming: intervention,
            nextPhase: phase,
            clientKind: session.clientInfo.kind
        )
        if !shouldPreserveExternalIntervention {
            session.intervention = intervention
        }
        if shouldPreserveExternalIntervention {
            if !session.phase.needsAttention {
                session.phase = phase
            }
        } else if shouldPreserveActivePhaseDuringApparentIdle(
            session: session,
            incomingPhase: phase,
            referenceDate: activityAt ?? Date(),
            previousLastActivity: existingLastActivity
        ) {
            // Keep the fresher active state until a stronger non-idle signal arrives.
        } else if shouldPreserveActivePhaseFromStaleCodexRefresh(
            currentPhase: session.phase,
            incomingPhase: phase,
            currentLastActivity: existingLastActivity,
            incomingActivityAt: activityAt ?? Date()
        ) {
            // Keep the fresher active state until Codex catches up with a newer snapshot.
        } else if session.phase.canTransition(to: phase) || session.phase == phase {
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
        if shouldPreserveCodexHookPermissionIngress(session: session) {
            session.ingress = .hookBridge
        } else if session.ingress != .hookBridge || (!session.phase.needsAttention && !hasIntervention) {
            session.ingress = .codexAppServer
        }
        if shouldPreserveActivePhaseDuringApparentIdle(
            session: session,
            incomingPhase: phase,
            referenceDate: activityAt ?? Date(),
            previousLastActivity: existingLastActivity
        ) {
            session.lastActivity = existingLastActivity ?? (activityAt ?? Date())
        } else {
            session.lastActivity = mergedLastActivity(
                existing: existingLastActivity,
                incoming: activityAt ?? Date()
            )
        }

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
            "Codex upsert session=\(resolvedSessionId, privacy: .public) sourceThread=\(sessionId, privacy: .public) phase=\(session.phase.description, privacy: .public) ingress=\(session.ingress.rawValue, privacy: .public) namePresent=\(name?.isEmpty == false, privacy: .public) previewPresent=\(preview?.isEmpty == false, privacy: .public) cwd=\(session.cwd, privacy: .public) filePathPresent=\(session.clientInfo.sessionFilePath?.isEmpty == false, privacy: .public) placeholderCandidate=\(placeholderCandidate, privacy: .public)"
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
        let existingLastActivity = sessions[resolvedSessionId]?.lastActivity
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
        session.codexParentThreadId = snapshot.parentThreadId
        session.codexSubagentDepth = snapshot.subagentDepth
        session.codexSubagentNickname = snapshot.subagentNickname
        session.codexSubagentRole = snapshot.subagentRole
        let shouldPreserveExternalIntervention = shouldPreserveExternalCodexIntervention(
            current: session.intervention,
            incoming: snapshot.intervention,
            nextPhase: snapshot.phase,
            clientKind: session.clientInfo.kind
        )
        if !shouldPreserveExternalIntervention {
            session.intervention = snapshot.intervention
        }
        if shouldPreserveExternalIntervention {
            if !session.phase.needsAttention {
                session.phase = snapshot.phase
            }
        } else if shouldPreserveActivePhaseDuringApparentIdle(
            session: session,
            incomingPhase: snapshot.phase,
            referenceDate: snapshot.updatedAt,
            previousLastActivity: existingLastActivity
        ) {
            // Keep the fresher active state until a stronger non-idle signal arrives.
        } else if shouldPreserveActivePhaseFromStaleCodexRefresh(
            currentPhase: session.phase,
            incomingPhase: snapshot.phase,
            currentLastActivity: existingLastActivity,
            incomingActivityAt: snapshot.updatedAt
        ) {
            // Keep the fresher active state until Codex catches up with a newer snapshot.
        } else if case .none = session.intervention {
            session.phase = snapshot.phase
        } else if snapshot.phase.needsAttention {
            session.phase = snapshot.phase
        }
        let hasIntervention: Bool
        if case .some = session.intervention {
            hasIntervention = true
        } else {
            hasIntervention = false
        }
        if shouldPreserveCodexHookPermissionIngress(session: session) {
            session.ingress = .hookBridge
        } else if ingress == .hookBridge {
            if session.ingress != .codexAppServer {
                session.ingress = .hookBridge
            }
        } else if session.ingress != .hookBridge || (!session.phase.needsAttention && !hasIntervention) {
            session.ingress = .codexAppServer
        }
        if shouldPreserveActivePhaseDuringApparentIdle(
            session: session,
            incomingPhase: snapshot.phase,
            referenceDate: snapshot.updatedAt,
            previousLastActivity: existingLastActivity
        ) {
            session.lastActivity = existingLastActivity ?? snapshot.updatedAt
        } else {
            session.lastActivity = mergedLastActivity(
                existing: existingLastActivity,
                incoming: snapshot.updatedAt
            )
        }

        let placeholderCandidate = isLikelyEmptyCodexPlaceholder(session)
        Self.logger.debug(
            "Codex snapshot sync session=\(resolvedSessionId, privacy: .public) sourceThread=\(snapshot.threadId, privacy: .public) ingress=\(ingress.rawValue, privacy: .public) historyItems=\(snapshot.historyItems.count, privacy: .public) namePresent=\(snapshot.name?.isEmpty == false, privacy: .public) previewPresent=\(snapshot.preview?.isEmpty == false, privacy: .public) filePathPresent=\(session.clientInfo.sessionFilePath?.isEmpty == false, privacy: .public) placeholderCandidate=\(placeholderCandidate, privacy: .public)"
        )

        sessions[resolvedSessionId] = session
        publishState()
        updateCodexPlaceholderPrune(for: session)
    }

    private func shouldPreserveExternalCodexIntervention(
        current: SessionIntervention?,
        incoming: SessionIntervention?,
        nextPhase: SessionPhase,
        clientKind: SessionClientKind
    ) -> Bool {
        guard let current else {
            return false
        }

        if let incoming,
           incoming.metadata["source"] == "codex_rollout_request_user_input",
           incoming.metadata["responseMode"] == "external_only",
           current.kind == .question,
           current.metadata["responseMode"] != "external_only" {
            return true
        }

        if case .some = incoming {
            return false
        }

        let source = current.metadata["source"] ?? ""
        if source == "codex_hook_permission" {
            return !nextPhase.needsAttention
        }

        guard clientKind == .codexCLI,
              current.metadata["responseMode"] == "external_only",
              source.hasPrefix("rollout_pending_mcp")
                || source.hasPrefix("app_server_pending_mcp")
                || source.hasPrefix("guardian_review")
        else {
            return false
        }

        return !nextPhase.needsAttention
    }

    private func shouldPreserveCodexHookPermissionIngress(session: SessionState) -> Bool {
        guard session.provider == .codex,
              session.intervention?.metadata["source"] == "codex_hook_permission",
              session.phase.needsAttention else {
            return false
        }
        return true
    }

    private func shouldPreserveActivePhaseFromStaleCodexRefresh(
        currentPhase: SessionPhase,
        incomingPhase: SessionPhase,
        currentLastActivity: Date?,
        incomingActivityAt: Date
    ) -> Bool {
        guard currentPhase.isActive else { return false }
        guard incomingPhase == .idle else { return false }
        guard let currentLastActivity else { return false }
        return incomingActivityAt < currentLastActivity
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

    private func applyClaudeTranscriptQuestionFallback(to session: inout SessionState) {
        guard session.provider == .claude,
              session.clientInfo.brand == .claude,
              session.ingress != .remoteBridge else { return }

        let fallbackSource = "claudeTranscriptQuestion"
        let currentSource = session.intervention?.metadata["source"]
        if let currentSource, currentSource != fallbackSource {
            return
        }

        guard let pendingQuestionTool = session.chatItems.reversed().compactMap({ item -> (id: String, tool: ToolCallItem)? in
            guard case .toolCall(let tool) = item.type else { return nil }
            let normalizedName = tool.name
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            guard normalizedName == "askuserquestion" else { return nil }
            guard tool.status == .running || tool.status == .waitingForApproval else { return nil }
            return (item.id, tool)
        }).first else {
            if currentSource == fallbackSource {
                session.intervention = nil
                if session.phase == .waitingForInput {
                    session.phase = .processing
                }
            }
            return
        }

        guard let intervention = claudeTranscriptQuestionIntervention(
            toolUseId: pendingQuestionTool.id,
            tool: pendingQuestionTool.tool,
            session: session
        ) else {
            return
        }

        session.intervention = intervention
        session.phase = .waitingForInput
        session.lastActivity = Date()
    }

    private func claudeTranscriptQuestionIntervention(
        toolUseId: String,
        tool: ToolCallItem,
        session: SessionState
    ) -> SessionIntervention? {
        guard let rawQuestions = tool.input["questions"],
              let data = rawQuestions.data(using: .utf8),
              let questions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !questions.isEmpty else {
            return nil
        }

        let parsedQuestions = questions.enumerated().compactMap { index, question -> SessionInterventionQuestion? in
            let prompt = (question["question"] as? String)
                ?? (question["prompt"] as? String)
                ?? (question["label"] as? String)
            guard let prompt, !prompt.isEmpty else { return nil }

            let objectOptions = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { optionIndex, option -> SessionInterventionOption? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return SessionInterventionOption(
                    id: option["id"] as? String ?? "\(index)-option-\(optionIndex)",
                    title: label,
                    detail: option["description"] as? String
                )
            }

            let normalizedOptions: [SessionInterventionOption]
            if !objectOptions.isEmpty {
                normalizedOptions = objectOptions
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

        let actorName = session.interactionDisplayName
        let title = parsedQuestions.count == 1
            ? "\(actorName) 的提问"
            : "\(actorName) 的提问（\(parsedQuestions.count) 个问题）"
        let payload: [String: Any] = ["questions": questions]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return nil
        }

        return SessionIntervention(
            id: toolUseId,
            kind: .question,
            title: title,
            message: "\(actorName) 需要你补充回答，提交后会继续执行当前会话。",
            options: [],
            questions: parsedQuestions,
            supportsSessionScope: false,
            metadata: [
                "toolName": "AskUserQuestion",
                "toolInputJSON": payloadJSON,
                "originalToolUseId": toolUseId,
                "source": "claudeTranscriptQuestion"
            ]
        )
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
            codexParentThreadId: previousSession.codexParentThreadId,
            codexSubagentDepth: previousSession.codexSubagentDepth,
            codexSubagentNickname: previousSession.codexSubagentNickname,
            codexSubagentRole: previousSession.codexSubagentRole,
            linkedParentSessionId: previousSession.linkedParentSessionId,
            linkedSubagentDisplayTitle: previousSession.linkedSubagentDisplayTitle,
            heuristicSubagentDisplayTitle: previousSession.heuristicSubagentDisplayTitle,
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

    private func enrichedGhosttyClientInfoIfNeeded(
        current: SessionClientInfo,
        event: HookEvent,
        workspacePath: String
    ) async -> SessionClientInfo? {
        // cmux is based on Ghostty, so we reuse the Ghostty enrichment logic
        guard current.terminalBundleIdentifier == "com.mitchellh.ghostty" || current.terminalBundleIdentifier == "com.cmuxterm.app",
              TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier(current.terminalSessionIdentifier) == nil,
              shouldCaptureFrontmostGhosttyTerminalIdentifier(for: event) else {
            return nil
        }

        guard let snapshot = await TerminalSessionFocuser.shared.frontmostGhosttyTerminalSnapshot(),
              TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier(snapshot.terminalSessionIdentifier) != nil,
              TerminalSessionFocuser.ghosttyWorkingDirectoryMatches(
                  snapshotWorkingDirectory: snapshot.workingDirectory,
                  workspacePath: workspacePath
              ) else {
            return nil
        }

        return SessionClientInfo(
            kind: current.kind,
            terminalSessionIdentifier: snapshot.terminalSessionIdentifier
        )
    }

    private func shouldCaptureFrontmostGhosttyTerminalIdentifier(for event: HookEvent) -> Bool {
        switch event.event {
        case "SessionStart", "UserPromptSubmit":
            return true
        default:
            return false
        }
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
        case .copilot:
            return clientInfo
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
        guard let message = Self.normalizedHookMessage(event.message) else {
            return false
        }

        return CodexAuxiliaryHookFilter.isCodexTitleGenerationPrompt(message)
    }

    private func shouldIgnoreClaudeAskUserQuestionPermissionRequest(_ event: HookEvent) -> Bool {
        guard event.provider == .claude,
              event.event == "PermissionRequest" else {
            return false
        }

        let profileID = event.clientInfo.profileID?.lowercased()
        let bundleIdentifier = event.clientInfo.bundleIdentifier?.lowercased()
        if profileID == "qoder"
            || profileID == "qoderwork"
            || profileID == "qwen-code"
            || bundleIdentifier == "com.qoder.ide"
            || bundleIdentifier == "com.qoder.work" {
            return false
        }

        let normalizedTool = event.tool?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return normalizedTool == "askuserquestion"
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
            "Pruning stale Codex placeholder session=\(sessionId, privacy: .public) phase=\(session.phase.description, privacy: .public)"
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
        case .remoteBridge:
            return codexHookPlaceholderPruneDelayNs
        case .codexAppServer:
            return codexAppServerPlaceholderPruneDelayNs
        case .nativeRuntime:
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
