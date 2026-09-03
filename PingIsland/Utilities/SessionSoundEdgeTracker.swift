import Foundation

/// Turns successive snapshots of the visible session list into semantic sound
/// events.
///
/// A sound must be caused by a session's own state changing. The list handed to the
/// Island is filtered, deduplicated, and sorted first, so a session can enter or
/// leave it for reasons that have nothing to do with that session — see
/// `SameWorkspaceSessionSupersession`. Differencing whole membership sets reads that
/// churn as "a session started processing" and chimes on every flip; the same shape
/// previously fired a spurious cue when a permission round-trip briefly left the set.
///
/// So the tracker records the last known state per `stableId` and keeps that record
/// while the session is missing from the list. Absence is not a state change, which
/// makes list churn inaudible by construction.
///
/// At most one event is emitted per snapshot, highest severity first, and it carries
/// only the sessions that actually crossed the edge so the focus-based mute in the
/// callers is evaluated against the terminals that caused the sound.
struct SessionSoundEdgeTracker {
    struct Edge: Equatable {
        let event: AppSoundFeedbackEvent
        let sessions: [SessionState]
    }

    /// The sound-relevant state of a single session at one point in time.
    private struct Snapshot {
        var isProcessing: Bool
        var needsAttention: Bool
        var completionKey: SessionCompletionKey?
        var isResourceLimited: Bool
        var errorToolIDs: Set<String>

        init(_ session: SessionState) {
            isProcessing = session.phase.contributesToProcessingSoundEdge
            needsAttention = SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge(session)
            completionKey = SessionCompletionKey.make(for: session)
            isResourceLimited = session.phase == .compacting
            errorToolIDs = session.completedErrorToolIDs
        }
    }

    private struct Record {
        var snapshot: Snapshot
        var lastSeenSequence: UInt64
    }

    /// Cap on retained records so a long-running app cannot accumulate one entry per
    /// session seen since launch. Only records for sessions that are currently absent
    /// from the list are evicted, oldest first.
    private let retainedSessionLimit: Int
    private var records: [String: Record] = [:]
    private var playedCompletionKeys = Set<SessionCompletionKey>()
    private var rapidSubmitTracker = RapidSubmitSoundTracker()
    private var sequence: UInt64 = 0
    private var hasPrimed = false

    init(retainedSessionLimit: Int = 512) {
        self.retainedSessionLimit = max(1, retainedSessionLimit)
    }

    var isPrimed: Bool { hasPrimed }

    /// Adopt the current state without emitting anything, so sessions that already
    /// exist when a surface appears do not chime retroactively.
    mutating func prime(with sessions: [SessionState]) {
        hasPrimed = true
        _ = rapidSubmitTracker.observe(sessions)
        absorb(sessions)
    }

    /// Record `sessions` and return the single sound edge they crossed, if any.
    mutating func edge(for sessions: [SessionState]) -> Edge? {
        guard hasPrimed else {
            prime(with: sessions)
            return nil
        }

        var errorSessions: [SessionState] = []
        var resourceLimitSessions: [SessionState] = []
        var attentionSessions: [SessionState] = []
        var completedSessions: [SessionState] = []
        var processingSessions: [SessionState] = []
        let newSessions = sessions.filter { records[$0.stableId] == nil }
        let rapidSubmitSessions = rapidSubmitTracker.observe(sessions)

        for session in sessions {
            let previous = records[session.stableId]?.snapshot
            let current = Snapshot(session)

            if !current.errorToolIDs.subtracting(previous?.errorToolIDs ?? []).isEmpty {
                errorSessions.append(session)
            }
            if current.isResourceLimited, previous?.isResourceLimited != true {
                resourceLimitSessions.append(session)
            }
            if current.needsAttention, previous?.needsAttention != true {
                attentionSessions.append(session)
            }
            if let completionKey = current.completionKey,
               !playedCompletionKeys.contains(completionKey) {
                completedSessions.append(session)
            }
            if current.isProcessing, previous?.isProcessing != true {
                processingSessions.append(session)
            }
        }

        absorb(sessions)

        if !errorSessions.isEmpty {
            return Edge(event: .taskError, sessions: errorSessions)
        }
        if !resourceLimitSessions.isEmpty {
            return Edge(event: .resourceLimit, sessions: resourceLimitSessions)
        }
        if !attentionSessions.isEmpty {
            return Edge(event: .attentionRequired, sessions: attentionSessions)
        }
        if !completedSessions.isEmpty {
            return Edge(event: .taskCompleted, sessions: completedSessions)
        }
        if !newSessions.isEmpty {
            return Edge(event: .sessionStarted, sessions: newSessions)
        }
        if !processingSessions.isEmpty {
            return Edge(event: .processingStarted, sessions: processingSessions)
        }
        if !rapidSubmitSessions.isEmpty {
            return Edge(event: .rapidSubmit, sessions: rapidSubmitSessions)
        }
        return nil
    }

    private mutating func absorb(_ sessions: [SessionState]) {
        sequence &+= 1

        for session in sessions {
            var snapshot = Snapshot(session)
            if let existing = records[session.stableId]?.snapshot {
                // Failed tool IDs only ever accumulate on a session; keep the ones
                // already announced so a rebuilt session cannot replay them.
                snapshot.errorToolIDs.formUnion(existing.errorToolIDs)
            }
            if let completionKey = snapshot.completionKey {
                playedCompletionKeys.insert(completionKey)
            }
            records[session.stableId] = Record(snapshot: snapshot, lastSeenSequence: sequence)
        }

        pruneRetainedRecords(visible: sessions)
    }

    private mutating func pruneRetainedRecords(visible: [SessionState]) {
        guard records.count > retainedSessionLimit else { return }

        let visibleIDs = Set(visible.map(\.stableId))
        let evictionOrder = records
            .filter { !visibleIDs.contains($0.key) }
            .sorted { $0.value.lastSeenSequence < $1.value.lastSeenSequence }

        var overflow = records.count - retainedSessionLimit
        for entry in evictionOrder {
            guard overflow > 0 else { break }
            records.removeValue(forKey: entry.key)
            overflow -= 1
        }
    }
}
