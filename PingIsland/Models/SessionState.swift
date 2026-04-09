//
//  SessionState.swift
//  PingIsland
//
//  Unified state model for a tracked session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

enum SessionScopedApprovalAction: Equatable, Sendable {
    case allowSession
    case autoApprove

    nonisolated var buttonTitle: String {
        switch self {
        case .allowSession:
            return "Allow Session"
        case .autoApprove:
            return "Auto-Approve"
        }
    }

    nonisolated var compactButtonTitle: String {
        switch self {
        case .allowSession:
            return "Session"
        case .autoApprove:
            return "Auto"
        }
    }
}

/// Complete state for a single tracked session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    private nonisolated static let minimalCompactDelay: TimeInterval = 10 * 60
    private nonisolated static let autoArchiveDelay: TimeInterval = 30 * 60
    private nonisolated static let codexContinuationPlaceholderHideWindow: TimeInterval = 10 * 60

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
    var autoApprovePermissions: Bool

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
        autoApprovePermissions: Bool = false,
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
        self.autoApprovePermissions = autoApprovePermissions
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
        sessionName
            ?? SessionTextSanitizer.sanitizedDisplayText(conversationInfo.summary)
            ?? SessionTextSanitizer.sanitizedDisplayText(conversationInfo.firstUserMessage)
            ?? projectName
    }

    /// Safety net for ghost Codex sessions that have no rollout, no history, and no visible content.
    nonisolated var shouldHideFromPrimaryUI: Bool {
        if shouldAutoArchiveFromPrimaryUI {
            return true
        }

        return isLikelyEmptyCodexPlaceholderForUI
    }

    /// Codex placeholder sessions can be created before a richer thread record is available.
    /// We treat sessions with no rollout path, no visible content, and no live interaction state
    /// as empty placeholders so they can be hidden or deduplicated in UI-facing collections.
    nonisolated var isLikelyEmptyCodexPlaceholderForUI: Bool {
        guard provider == .codex else { return false }
        guard chatItems.isEmpty else { return false }
        guard case .none = intervention else { return false }
        guard clientInfo.sessionFilePath?.isEmpty != false else { return false }
        if hasOnlyTransientCodexProgressContent {
            return true
        }
        guard compactHookMessage == nil else { return false }
        return !hasMeaningfulCodexDisplayContent
    }

    nonisolated var hasMeaningfulCodexDisplayContent: Bool {
        !chatItems.isEmpty
            || intervention != nil
            || (compactHookMessage != nil && !hasOnlyTransientCodexProgressContent)
            || (clientInfo.sessionFilePath?.isEmpty == false)
            || (sessionName?.isEmpty == false)
            || (SessionTextSanitizer.sanitizedDisplayText(previewText) != nil && !hasOnlyTransientCodexProgressContent)
            || (conversationInfo.summary?.isEmpty == false)
            || (conversationInfo.firstUserMessage?.isEmpty == false)
            || (conversationInfo.lastMessage?.isEmpty == false)
    }

    /// Some Codex App continuation updates briefly appear as a new thread ID with only a shallow
    /// status preview (for example "working..."), but without any rollout path or durable history.
    /// We treat those as continuation placeholders so they can be rebound onto the richer thread.
    nonisolated var isLikelyTransientCodexContinuationPlaceholder: Bool {
        guard provider == .codex else { return false }
        guard chatItems.isEmpty else { return false }
        guard intervention == nil else { return false }
        guard clientInfo.sessionFilePath?.isEmpty != false else { return false }
        guard sessionName?.isEmpty != false else { return false }
        guard conversationInfo.summary?.isEmpty != false else { return false }
        guard conversationInfo.firstUserMessage?.isEmpty != false else { return false }
        guard conversationInfo.lastMessage?.isEmpty != false else { return false }
        if let compactHookMessage, !Self.isLikelyGenericCodexProgressText(compactHookMessage) {
            return false
        }
        return hasOnlyTransientCodexProgressContent || isLikelyEmptyCodexPlaceholderForUI
    }

    nonisolated var hasDurableCodexThreadIdentity: Bool {
        !chatItems.isEmpty
            || intervention != nil
            || compactHookMessage != nil
            || (clientInfo.sessionFilePath?.isEmpty == false)
            || (sessionName?.isEmpty == false)
            || (conversationInfo.summary?.isEmpty == false)
            || (conversationInfo.firstUserMessage?.isEmpty == false)
            || (conversationInfo.lastMessage?.isEmpty == false)
    }

    nonisolated func shouldRebindToExistingCodexThread(
        comparedTo other: SessionState,
        maximumRecencyGap: TimeInterval
    ) -> Bool {
        guard sessionId != other.sessionId else { return false }
        guard isLikelyTransientCodexContinuationPlaceholder else { return false }
        guard other.provider == .codex else { return false }
        guard other.hasDurableCodexThreadIdentity else { return false }
        guard normalizedWorkspacePath == other.normalizedWorkspacePath else { return false }

        let recencyGap = abs(lastActivity.timeIntervalSince(other.lastActivity))
        guard recencyGap <= maximumRecencyGap else { return false }
        return true
    }

    nonisolated func shouldHideAsDuplicateCodexPlaceholder(comparedTo other: SessionState) -> Bool {
        guard sessionId != other.sessionId else { return false }
        guard isLikelyEmptyCodexPlaceholderForUI || isLikelyTransientCodexContinuationPlaceholder else { return false }
        guard other.provider == .codex else { return false }
        guard other.hasDurableCodexThreadIdentity else { return false }
        guard normalizedWorkspacePath == other.normalizedWorkspacePath else { return false }

        let sharedIdentity = !codexSurfaceIdentityTokens.isDisjoint(with: other.codexSurfaceIdentityTokens)
        if sharedIdentity {
            return true
        }

        let recencyGap = abs(lastActivity.timeIntervalSince(other.lastActivity))
        if isLikelyTransientCodexContinuationPlaceholder {
            return recencyGap <= Self.codexContinuationPlaceholderHideWindow
        }

        guard other.clientInfo.sessionFilePath?.isEmpty == false else { return false }
        return recencyGap <= 120
    }

    private nonisolated var hasOnlyTransientCodexProgressContent: Bool {
        guard provider == .codex else { return false }
        guard chatItems.isEmpty else { return false }
        guard intervention == nil else { return false }
        guard clientInfo.sessionFilePath?.isEmpty != false else { return false }
        guard sessionName?.isEmpty != false else { return false }
        guard conversationInfo.summary?.isEmpty != false else { return false }
        guard conversationInfo.firstUserMessage?.isEmpty != false else { return false }
        guard conversationInfo.lastMessage?.isEmpty != false else { return false }

        let visibleTexts = [
            SessionTextSanitizer.sanitizedDisplayText(previewText),
            compactHookMessage
        ].compactMap { $0 }

        guard !visibleTexts.isEmpty else { return false }
        return visibleTexts.allSatisfy(Self.isLikelyGenericCodexProgressText(_:))
    }

    private nonisolated static func isLikelyGenericCodexProgressText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"^codex\s*:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[….]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return false }

        let exactMatches: Set<String> = [
            "working",
            "working on it",
            "processing",
            "thinking",
            "loading",
            "starting",
            "running",
            "busy",
            "work in progress",
            "codex is still working",
            "工作中",
            "处理中",
            "正在处理",
            "思考中",
            "加载中",
            "准备中",
            "运行中",
            "正在压缩上下文"
        ]
        if exactMatches.contains(normalized) {
            return true
        }

        let containsMatches = [
            "still working",
            "working",
            "processing",
            "thinking",
            "loading",
            "compacting context",
            "工作中",
            "处理中",
            "正在处理",
            "思考中",
            "压缩上下文"
        ]
        return containsMatches.contains { normalized.contains($0) }
    }

    /// Provider label for message prefixes and generic copy.
    nonisolated var providerDisplayName: String {
        clientInfo.assistantLabel(for: provider)
    }

    /// Client label for badges and source-aware copy.
    nonisolated var clientDisplayName: String {
        clientInfo.badgeLabel(for: provider)
    }

    /// Message surfaces keep Codex App branding compact to avoid showing both
    /// "Codex App" and "Codex" inside the same preview block.
    nonisolated var messageBadgeDisplayName: String {
        if provider == .codex, clientInfo.kind == .codexApp {
            return providerDisplayName
        }
        return clientDisplayName
    }

    /// Human-facing actor for questions/approvals. Prefer the IDE host when present.
    nonisolated var interactionDisplayName: String {
        clientInfo.interactionLabel(for: provider)
    }

    /// Optional IDE-host badge when the terminal is hosted inside an editor.
    nonisolated var ideHostBadgeLabel: String? {
        deduplicatedSecondaryBadgeLabel(clientInfo.ideHostBadgeLabel(for: provider))
    }

    /// Optional terminal-source badge for terminal-hosted sessions such as Ghostty or iTerm2.
    nonisolated var terminalSourceBadgeLabel: String? {
        deduplicatedSecondaryBadgeLabel(clientInfo.terminalSourceDisplayName)
    }

    /// Best hint for matching window title
    nonisolated var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    private nonisolated func deduplicatedSecondaryBadgeLabel(_ label: String?) -> String? {
        guard let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedLabel.isEmpty else {
            return nil
        }

        let reservedLabels = [
            messageBadgeDisplayName,
            providerDisplayName,
            clientDisplayName
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

        guard !reservedLabels.contains(trimmedLabel.lowercased()) else {
            return nil
        }

        return trimmedLabel
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
        SessionTextSanitizer.sanitizedDisplayText(conversationInfo.lastMessage)
            ?? SessionTextSanitizer.sanitizedDisplayText(previewText)
            ?? SessionTextSanitizer.sanitizedDisplayText(intervention?.summaryText)
    }

    /// Latest hook bridge message formatted for compact notch display.
    nonisolated var compactHookMessage: String? {
        guard let latestHookMessage else { return nil }
        let normalized = latestHookMessage
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.caseInsensitiveCompare("Stop") == .orderedSame {
            return nil
        }
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

    nonisolated var scopedApprovalAction: SessionScopedApprovalAction? {
        guard needsApprovalResponse else { return nil }

        if ingress == .codexAppServer || intervention?.supportsSessionScope == true {
            return .allowSession
        }

        if provider == .claude, clientInfo.kind == .claudeCode {
            return .autoApprove
        }

        return nil
    }

    nonisolated var supportsSessionScopedApproval: Bool {
        scopedApprovalAction != nil
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

    /// Sessions with no new activity for long enough should disappear from the primary list
    /// until a new event or message refreshes `lastActivity`.
    nonisolated var shouldAutoArchiveFromPrimaryUI: Bool {
        if needsManualAttention {
            return false
        }
        return Date().timeIntervalSince(lastActivity) >= Self.autoArchiveDelay
    }

    /// Older background sessions collapse to a header-only presentation in compact surfaces.
    nonisolated var shouldUseMinimalCompactPresentation: Bool {
        if shouldAutoArchiveFromPrimaryUI {
            return false
        }
        if phase.isActive || needsManualAttention {
            return false
        }
        return Date().timeIntervalSince(lastActivity) >= Self.minimalCompactDelay
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

    private nonisolated var normalizedWorkspacePath: String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path.lowercased()
    }

    private nonisolated var codexSurfaceIdentityTokens: Set<String> {
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed.lowercased()
        }

        func normalizedClientName(_ value: String?) -> String? {
            guard let normalized = normalized(value) else { return nil }
            switch normalized {
            case "codex", "codex app", "codex cli":
                return nil
            default:
                return normalized
            }
        }

        return Set([
            normalizedClientName(clientInfo.name).map { "name:\($0)" },
            normalizedClientName(clientInfo.originator).map { "originator:\($0)" },
            normalized(clientInfo.threadSource).map { "threadSource:\($0)" },
            normalized(clientInfo.terminalBundleIdentifier).map { "terminalBundle:\($0)" },
            normalized(clientInfo.terminalProgram).map { "terminalProgram:\($0)" },
            normalized(clientInfo.transport).map { "transport:\($0)" },
            normalized(clientInfo.remoteHost).map { "remoteHost:\($0)" },
            normalized(clientInfo.terminalSessionIdentifier).map { "terminalSession:\($0)" },
            normalized(clientInfo.iTermSessionIdentifier).map { "itermSession:\($0)" },
            normalized(clientInfo.tmuxSessionIdentifier).map { "tmuxSession:\($0)" },
            normalized(clientInfo.tmuxPaneIdentifier).map { "tmuxPane:\($0)" },
            normalized(clientInfo.processName).map { "process:\($0)" }
        ].compactMap { $0 })
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
