import Foundation
struct SessionManualAttentionTracker {
    private var previousApprovalIds = Set<String>()
    private var previousQuestionIds = Set<String>()
    private var previousQuestionInterventionIDs: [String: String] = [:]

    mutating func consumeNewAttentionSession(from instances: [SessionState]) -> SessionState? {
        let approvalSessions = instances.filter { $0.needsApprovalResponse }
        let currentApprovalIds = Set(approvalSessions.map(\.stableId))
        let newApprovalIds = currentApprovalIds.subtracting(previousApprovalIds)

        let questionSessions = instances.filter { $0.needsQuestionResponse }
        let currentQuestionIds = Set(questionSessions.map(\.stableId))
        let currentQuestionInterventionIDs = Dictionary(
            uniqueKeysWithValues: questionSessions.map { session in
                (session.stableId, session.intervention?.id ?? "")
            }
        )
        let newQuestionIds = currentQuestionIds.subtracting(previousQuestionIds)
        let refreshedQuestionIds = Set<String>(
            currentQuestionInterventionIDs.compactMap { sessionId, interventionId in
                guard let previousInterventionId = previousQuestionInterventionIDs[sessionId],
                      !previousInterventionId.isEmpty,
                      previousInterventionId != interventionId else {
                    return nil
                }
                return sessionId
            }
        )
        let attentionQuestionIds = newQuestionIds.union(refreshedQuestionIds)

        defer {
            previousApprovalIds = currentApprovalIds
            previousQuestionIds = currentQuestionIds
            previousQuestionInterventionIDs = currentQuestionInterventionIDs
        }

        let attentionCandidates = instances.filter { session in
            newApprovalIds.contains(session.stableId) || attentionQuestionIds.contains(session.stableId)
        }

        return attentionCandidates.sorted(by: attentionSort).first
    }

    nonisolated private func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastUserMessageDate ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastUserMessageDate ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}
