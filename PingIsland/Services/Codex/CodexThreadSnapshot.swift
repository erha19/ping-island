import Foundation

struct CodexThreadSnapshot: Equatable, Sendable {
    let threadId: String
    let name: String?
    let preview: String?
    let cwd: String
    let clientInfo: SessionClientInfo?
    let createdAt: Date
    let updatedAt: Date
    let phase: SessionPhase
    let historyItems: [ChatHistoryItem]
    let conversationInfo: ConversationInfo
    let latestTurnId: String?
    let latestResponseText: String?
    let latestResponsePhase: String?
    let latestUserText: String?

    nonisolated var displayResultText: String? {
        latestResponseText ?? conversationInfo.lastMessage ?? preview
    }
}
