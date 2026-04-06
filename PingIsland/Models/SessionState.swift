//
//  SessionState.swift
//  PingIsland
//
//  Unified state model for a tracked session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

/// Complete state for a single tracked session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    var cwd: String
    var projectName: String
    var provider: SessionProvider
    var clientInfo: SessionClientInfo
    var ingress: SessionIngress
    var sessionName: String?
    var previewText: String?
    var latestHookMessage: String?
    var intervention: SessionIntervention?

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    /// Tool IDs that completed with an actual execution error.
    /// Used for event-specific notifications such as CESP `task.error`.
    var completedErrorToolIDs: Set<String>

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        provider: SessionProvider = .claude,
        clientInfo: SessionClientInfo? = nil,
        ingress: SessionIngress = .hookBridge,
        sessionName: String? = nil,
        previewText: String? = nil,
        latestHookMessage: String? = nil,
        intervention: SessionIntervention? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        completedErrorToolIDs: Set<String> = [],
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.provider = provider
        self.clientInfo = clientInfo ?? SessionClientInfo.default(for: provider)
        self.ingress = ingress
        self.sessionName = sessionName
        self.previewText = previewText
        self.latestHookMessage = latestHookMessage
        self.intervention = intervention
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.completedErrorToolIDs = completedErrorToolIDs
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    nonisolated var needsAttention: Bool {
        phase.needsAttention || intervention != nil
    }

    /// Whether this session should be surfaced before active/background work.
    nonisolated var needsManualAttention: Bool {
        needsAttention
    }

    /// The active permission context, if any
    nonisolated var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    nonisolated var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Display title: summary > first user message > project name
    nonisolated var displayTitle: String {
        sessionName ?? conversationInfo.summary ?? conversationInfo.firstUserMessage ?? projectName
    }

    /// Provider label for message prefixes and generic copy.
    nonisolated var providerDisplayName: String {
        clientInfo.assistantLabel(for: provider)
    }

    /// Client label for badges and source-aware copy.
    nonisolated var clientDisplayName: String {
        clientInfo.badgeLabel(for: provider)
    }

    /// Optional IDE-host badge when the terminal is hosted inside an editor.
    nonisolated var ideHostBadgeLabel: String? {
        clientInfo.ideHostBadgeLabel(for: provider)
    }

    /// Best hint for matching window title
    nonisolated var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// Pending tool name if waiting for approval
    nonisolated var pendingToolName: String? {
        activePermission?.toolName ?? intervention?.title
    }

    /// Pending tool use ID
    nonisolated var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    nonisolated var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    nonisolated var lastMessage: String? {
        conversationInfo.lastMessage ?? previewText ?? intervention?.summaryText
    }

    /// Latest hook bridge message formatted for compact notch display.
    nonisolated var compactHookMessage: String? {
        guard let latestHookMessage else { return nil }
        let normalized = latestHookMessage
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Last message role
    nonisolated var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    nonisolated var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    nonisolated var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    nonisolated var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    nonisolated var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session can be interacted with
    nonisolated var canInteract: Bool {
        phase.needsAttention || intervention != nil
    }

    /// Whether the session is waiting on a question-like intervention
    nonisolated var needsQuestionResponse: Bool {
        intervention?.kind == .question
    }

    /// Whether the session is waiting on an approval-like decision.
    nonisolated var needsApprovalResponse: Bool {
        phase.isWaitingForApproval || intervention?.kind == .approval
    }

    /// Timestamp used when sorting sessions that need manual attention.
    nonisolated var attentionRequestedAt: Date? {
        if let permission = activePermission {
            return permission.receivedAt
        }
        if needsAttention {
            return lastActivity
        }
        return nil
    }

    /// Timestamp used for recency ordering once attention-demanding sessions are handled.
    nonisolated var queueSortActivityDate: Date {
        lastUserMessageDate ?? lastActivity
    }

    /// Older background sessions collapse to a header-only presentation in compact surfaces.
    nonisolated var shouldUseMinimalCompactPresentation: Bool {
        if phase.isActive || needsManualAttention {
            return false
        }
        return Date().timeIntervalSince(lastActivity) >= 10 * 60
    }

    nonisolated func shouldSortBeforeInQueue(_ other: SessionState) -> Bool {
        if needsManualAttention != other.needsManualAttention {
            return needsManualAttention
        }

        if needsManualAttention, other.needsManualAttention {
            let dateA = attentionRequestedAt ?? createdAt
            let dateB = other.attentionRequestedAt ?? other.createdAt
            if dateA != dateB {
                return dateA < dateB
            }
        }

        let priorityA = queuePhasePriority
        let priorityB = other.queuePhasePriority
        if priorityA != priorityB {
            return priorityA < priorityB
        }

        let dateA = queueSortActivityDate
        let dateB = other.queueSortActivityDate
        if dateA != dateB {
            return dateA > dateB
        }

        return stableId < other.stableId
    }

    private nonisolated var queuePhasePriority: Int {
        if needsManualAttention {
            return 0
        }

        switch phase {
        case .processing, .compacting:
            return 1
        case .idle:
            return 2
        case .ended:
            return 3
        case .waitingForInput, .waitingForApproval:
            return 0
        }
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
