import Foundation

struct CodexThreadSnapshot: Equatable, Sendable {
    let threadId: String
    let name: String?
    let preview: String?
    let cwd: String
    let parentThreadId: String?
    let subagentDepth: Int?
    let subagentNickname: String?
    let subagentRole: String?
    let clientInfo: SessionClientInfo?
    let intervention: SessionIntervention?
    let createdAt: Date
    let updatedAt: Date
    let phase: SessionPhase
    let historyItems: [ChatHistoryItem]
    let conversationInfo: ConversationInfo
    let latestTurnId: String?
    let latestResponseText: String?
    let latestResponsePhase: String?
    let latestUserText: String?
    let isTurnInterrupted: Bool

    nonisolated init(
        threadId: String,
        name: String?,
        preview: String?,
        cwd: String,
        parentThreadId: String? = nil,
        subagentDepth: Int? = nil,
        subagentNickname: String? = nil,
        subagentRole: String? = nil,
        clientInfo: SessionClientInfo?,
        intervention: SessionIntervention?,
        createdAt: Date,
        updatedAt: Date,
        phase: SessionPhase,
        historyItems: [ChatHistoryItem],
        conversationInfo: ConversationInfo,
        latestTurnId: String?,
        latestResponseText: String?,
        latestResponsePhase: String?,
        latestUserText: String?,
        isTurnInterrupted: Bool = false
    ) {
        self.threadId = threadId
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.parentThreadId = parentThreadId
        self.subagentDepth = subagentDepth
        self.subagentNickname = subagentNickname
        self.subagentRole = subagentRole
        self.clientInfo = clientInfo
        self.intervention = intervention
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.historyItems = historyItems
        self.conversationInfo = conversationInfo
        self.latestTurnId = latestTurnId
        self.latestResponseText = latestResponseText
        self.latestResponsePhase = latestResponsePhase
        self.latestUserText = latestUserText
        self.isTurnInterrupted = isTurnInterrupted
    }

    nonisolated var isSubagent: Bool {
        parentThreadId?.isEmpty == false || subagentDepth != nil
    }

    nonisolated var displayResultText: String? {
        latestResponseText ?? conversationInfo.lastMessage ?? preview
    }

    nonisolated var hasCompletedAssistantReply: Bool {
        for item in historyItems.reversed() {
            switch item.type {
            case .assistant:
                return true
            case .user, .thinking, .toolCall, .interrupted:
                return false
            }
        }

        return conversationInfo.lastMessageRole == "assistant"
    }

    /// Chooses which view of a Codex thread `SessionStore` should apply after reading
    /// both app-server and rollout snapshots. Never drops both — Desktop `notLoaded`
    /// list rows are often idle/empty while `thread/read` or the jsonl still show work.
    nonisolated static func preferredForSync(
        rollout: CodexThreadSnapshot,
        appServer: CodexThreadSnapshot?
    ) -> (snapshot: CodexThreadSnapshot, ingress: SessionIngress) {
        guard let appServer else {
            return (rollout, .hookBridge)
        }

        // Prefer a live rollout over a stale idle app-server snapshot when Desktop
        // owns the runtime and PingIsland's app-server lags behind the jsonl.
        if rollout.phase.isActive && !appServer.phase.isActive {
            return (rollout, .hookBridge)
        }
        if case .some = rollout.intervention, case .none = appServer.intervention {
            return (rollout, .hookBridge)
        }

        let preferAppServer =
            rollout.historyItems.count <= appServer.historyItems.count
            && rollout.updatedAt <= appServer.updatedAt
        if preferAppServer {
            return (appServer, .codexAppServer)
        }

        return (rollout, .hookBridge)
    }
}
