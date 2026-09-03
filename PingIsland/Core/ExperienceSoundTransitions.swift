import Foundation

/// Pure transition evaluators for the additional semantic sound moments. They
/// do not know which theme or concrete audio file is active.
enum UsageSoundTransitionEvaluator {
    nonisolated static func maximumUsedPercentage(
        claude: ClaudeUsageSnapshot?,
        codex: CodexUsageSnapshot?
    ) -> Double? {
        let claudeValues = [claude?.fiveHour?.usedPercentage, claude?.sevenDay?.usedPercentage]
            .compactMap { $0 }
        let codexValues = codex?.windows.map(\.usedPercentage) ?? []
        return (claudeValues + codexValues).max()
    }

    nonisolated static func event(previous: Double?, current: Double?) -> AppSoundFeedbackEvent? {
        guard let previous, let current else { return nil }
        if previous < 90, current >= 90 { return .usageWarning }
        if previous >= 50, current <= 20 { return .usageReset }
        return nil
    }
}

struct RapidSubmitSoundTracker {
    private let retainedSessionLimit: Int
    private var hasPrimed = false
    private var lastObservedMessageDate: [String: Date] = [:]
    private var recentSubmissions: [String: [Date]] = [:]
    private var lastTriggeredAt: [String: Date] = [:]
    private var lastSeenSequence: [String: UInt64] = [:]
    private var sequence: UInt64 = 0

    init(retainedSessionLimit: Int = 512) {
        self.retainedSessionLimit = max(1, retainedSessionLimit)
    }

    mutating func observe(_ sessions: [SessionState], now: Date = Date()) -> [SessionState] {
        sequence &+= 1
        for session in sessions {
            lastSeenSequence[session.stableId] = sequence
        }

        guard hasPrimed else {
            for session in sessions {
                lastObservedMessageDate[session.stableId] = session.lastUserMessageDate
            }
            hasPrimed = true
            pruneRetainedSessions(visible: sessions)
            return []
        }

        var triggered: [SessionState] = []
        for session in sessions {
            guard let messageDate = session.lastUserMessageDate else { continue }
            let id = session.stableId
            defer { lastObservedMessageDate[id] = messageDate }

            guard messageDate > (lastObservedMessageDate[id] ?? .distantPast),
                  abs(now.timeIntervalSince(messageDate)) <= 12 else {
                continue
            }

            var timestamps = recentSubmissions[id] ?? []
            timestamps.append(messageDate)
            timestamps.removeAll { now.timeIntervalSince($0) > 10 }
            recentSubmissions[id] = timestamps

            if timestamps.count >= 3,
               now.timeIntervalSince(lastTriggeredAt[id] ?? .distantPast) >= 10 {
                lastTriggeredAt[id] = now
                recentSubmissions[id] = []
                triggered.append(session)
            }
        }
        pruneRetainedSessions(visible: sessions)
        return triggered
    }

    /// A filtered session list may temporarily omit a still-running session. Keep
    /// its recent-submit history across that churn, while bounding long-term state.
    private mutating func pruneRetainedSessions(visible sessions: [SessionState]) {
        guard lastSeenSequence.count > retainedSessionLimit else { return }

        let visibleIDs = Set(sessions.map(\.stableId))
        let evictionOrder = lastSeenSequence
            .filter { !visibleIDs.contains($0.key) }
            .sorted { $0.value < $1.value }

        var overflow = lastSeenSequence.count - retainedSessionLimit
        for entry in evictionOrder {
            guard overflow > 0 else { break }
            let id = entry.key
            lastSeenSequence.removeValue(forKey: id)
            lastObservedMessageDate.removeValue(forKey: id)
            recentSubmissions.removeValue(forKey: id)
            lastTriggeredAt.removeValue(forKey: id)
            overflow -= 1
        }
    }
}

struct IdleReminderSoundTracker {
    nonisolated static let reminderDelay: TimeInterval = 5 * 60
    private var remindedSessionIDs: Set<String> = []

    mutating func sessionsNeedingReminder(
        from sessions: [SessionState],
        now: Date = Date()
    ) -> [SessionState] {
        let eligible = sessions.filter { session in
            session.phase == .waitingForInput
                && now.timeIntervalSince(session.lastActivity) >= Self.reminderDelay
        }
        let eligibleIDs = Set(eligible.map(\.stableId))
        remindedSessionIDs.formIntersection(eligibleIDs)

        let result = eligible.filter { !remindedSessionIDs.contains($0.stableId) }
        remindedSessionIDs.formUnion(result.map(\.stableId))
        return result
    }
}
