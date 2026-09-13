import Foundation
struct SessionManualAttentionTracker {
    static let autoApproveApprovalNotificationDelay: TimeInterval = 1.25

    private struct DelayedApprovalNotification {
        let readyAt: Date
        var wasPresented: Bool
    }

    private var previousApprovalIds = Set<String>()
    private var previousApprovalToolUseIDs: [String: String] = [:]
    private var previousQuestionIds = Set<String>()
    private var previousQuestionInterventionIDs: [String: String] = [:]
    private var previousTerminalRoutedPromptIds = Set<String>()
    private var previousTerminalRoutedPromptKeys: [String: String] = [:]
    private var delayedApprovalNotifications: [String: DelayedApprovalNotification] = [:]

    mutating func consumeNewAttentionSession(
        from instances: [SessionState],
        suppressAutoOpen: @autoclosure () -> Bool = false,
        now: Date = Date()
    ) -> SessionState? {
        let approvalSessions = instances.filter { $0.needsApprovalResponse }
        let approvalSessionsByStableId = Dictionary(
            uniqueKeysWithValues: approvalSessions.map { ($0.stableId, $0) }
        )
        let currentApprovalIds = Set(approvalSessions.map(\.stableId))
        let currentApprovalToolUseIDs = Dictionary(
            uniqueKeysWithValues: approvalSessions.map { session in
                (session.stableId, session.activePermission?.toolUseId ?? "")
            }
        )
        let newApprovalIds = currentApprovalIds.subtracting(previousApprovalIds)
        let refreshedApprovalIds = Set<String>(
            currentApprovalToolUseIDs.compactMap { sessionId, toolUseId in
                guard let previousToolUseId = previousApprovalToolUseIDs[sessionId],
                      !previousToolUseId.isEmpty,
                      !toolUseId.isEmpty,
                      previousToolUseId != toolUseId else {
                    return nil
                }
                return sessionId
            }
        )
        let changedApprovalIds = newApprovalIds.union(refreshedApprovalIds)
        let delayedApprovalIds = updateDelayedApprovalNotifications(
            from: approvalSessions,
            changedApprovalIds: changedApprovalIds,
            now: now
        )
        let immediateApprovalIds = Set(changedApprovalIds.filter { stableId in
            guard let session = approvalSessionsByStableId[stableId] else { return false }
            return !shouldDelayApprovalNotification(for: session)
                || approvalRequestKey(for: session) == nil
        })
        let attentionApprovalIds = immediateApprovalIds.union(delayedApprovalIds)

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

        let terminalRoutedPromptSessions = instances.filter(\.suppressInAppPromptControls)
        let currentTerminalRoutedPromptIds = Set(terminalRoutedPromptSessions.map(\.stableId))
        let currentTerminalRoutedPromptKeys = Dictionary(
            uniqueKeysWithValues: terminalRoutedPromptSessions.map { session in
                (
                    session.stableId,
                    session.activePermission?.toolUseId
                        ?? session.intervention?.id
                        ?? session.phase.description
                )
            }
        )
        let newTerminalRoutedPromptIds = currentTerminalRoutedPromptIds
            .subtracting(previousTerminalRoutedPromptIds)
        let refreshedTerminalRoutedPromptIds = Set<String>(
            currentTerminalRoutedPromptKeys.compactMap { sessionId, promptKey in
                guard let previousPromptKey = previousTerminalRoutedPromptKeys[sessionId],
                      previousPromptKey != promptKey else {
                    return nil
                }
                return sessionId
            }
        )
        let attentionTerminalRoutedPromptIds = newTerminalRoutedPromptIds
            .union(refreshedTerminalRoutedPromptIds)

        defer {
            previousApprovalIds = currentApprovalIds
            previousApprovalToolUseIDs = currentApprovalToolUseIDs
            previousQuestionIds = currentQuestionIds
            previousQuestionInterventionIDs = currentQuestionInterventionIDs
            previousTerminalRoutedPromptIds = currentTerminalRoutedPromptIds
            previousTerminalRoutedPromptKeys = currentTerminalRoutedPromptKeys
        }

        let attentionCandidates = instances.filter { session in
            attentionApprovalIds.contains(session.stableId)
                || attentionQuestionIds.contains(session.stableId)
                || attentionTerminalRoutedPromptIds.contains(session.stableId)
        }

        let target = attentionCandidates.sorted(by: attentionSort).first
        markDelayedApprovalNotificationPresentedIfNeeded(for: target)
        // Suppressed edges are still consumed, including delayed auto-approve
        // requests. Going idle later must not replay an old notification.
        guard target != nil, !suppressAutoOpen() else { return nil }
        return target
    }

    mutating func nextDelayedAttentionDate(
        from instances: [SessionState],
        now: Date = Date()
    ) -> Date? {
        pruneDelayedApprovalNotifications(using: instances)
        return delayedApprovalNotifications.values
            .filter { !$0.wasPresented && $0.readyAt > now }
            .map(\.readyAt)
            .min()
    }

    private mutating func updateDelayedApprovalNotifications(
        from approvalSessions: [SessionState],
        changedApprovalIds: Set<String>,
        now: Date
    ) -> Set<String> {
        pruneDelayedApprovalNotifications(using: approvalSessions)

        var readyApprovalIds = Set<String>()

        for session in approvalSessions {
            guard let requestKey = approvalRequestKey(for: session) else { continue }

            guard shouldDelayApprovalNotification(for: session) else {
                if delayedApprovalNotifications.removeValue(forKey: requestKey) != nil {
                    readyApprovalIds.insert(session.stableId)
                }
                continue
            }

            if delayedApprovalNotifications[requestKey] == nil,
                changedApprovalIds.contains(session.stableId) {
                delayedApprovalNotifications[requestKey] = DelayedApprovalNotification(
                    readyAt: now.addingTimeInterval(Self.autoApproveApprovalNotificationDelay),
                    wasPresented: false
                )
            }

            guard let delayed = delayedApprovalNotifications[requestKey],
                  !delayed.wasPresented,
                  delayed.readyAt <= now else {
                continue
            }

            readyApprovalIds.insert(session.stableId)
        }

        return readyApprovalIds
    }

    private mutating func pruneDelayedApprovalNotifications(using instances: [SessionState]) {
        let currentApprovalRequestKeys = Set(
            instances
                .filter(\.needsApprovalResponse)
                .compactMap { approvalRequestKey(for: $0) }
        )
        delayedApprovalNotifications = delayedApprovalNotifications.filter { key, _ in
            currentApprovalRequestKeys.contains(key)
        }
    }

    private mutating func markDelayedApprovalNotificationPresentedIfNeeded(for session: SessionState?) {
        guard let session,
              let requestKey = approvalRequestKey(for: session),
              var delayed = delayedApprovalNotifications[requestKey] else {
            return
        }

        delayed.wasPresented = true
        delayedApprovalNotifications[requestKey] = delayed
    }

    private nonisolated func shouldDelayApprovalNotification(for session: SessionState) -> Bool {
        session.autoApprovePermissions && session.needsApprovalResponse
    }

    private nonisolated func approvalRequestKey(for session: SessionState) -> String? {
        guard session.needsApprovalResponse else { return nil }

        let requestId = [
            session.activePermission?.toolUseId,
            session.intervention?.metadata["originalToolUseId"],
            session.intervention?.metadata["toolUseId"],
            session.intervention?.metadata["tool_use_id"],
            session.intervention?.id
        ].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first

        guard let requestId else { return nil }
        return "\(session.stableId):\(requestId)"
    }

    nonisolated private func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastUserMessageDate ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastUserMessageDate ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}
