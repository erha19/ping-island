import Foundation

nonisolated struct CodexThreadReadState: Sendable {
    let intervention: SessionIntervention?
}

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
}
