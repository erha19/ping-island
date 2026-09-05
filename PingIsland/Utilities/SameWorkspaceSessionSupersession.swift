import Darwin
import Foundation

/// Shared rule for "may a newer session in this workspace take this one's place?".
///
/// Two layers ask that question and must answer it identically:
/// - `SessionStore.endOrphanedSessions` archives superseded sessions when a new
///   session starts in the same `provider + cwd`.
/// - `SessionMonitor.filteredVisibleSessions` hides them from the primary list
///   during the window before the store's liveness sweep catches up.
///
/// Keeping the rule in one place matters because the two copies drifted before.
/// The store learned that concurrent Qwen Code sessions legitimately share a
/// workspace, while the display filter kept collapsing them; and the display
/// filter kept only the most recently active session per directory, so two live
/// Claude CLI sessions in one project became a single row that flipped between
/// them on every hook event.
///
/// The invariant both layers rely on: whether a session is displayed depends on
/// that session alone. A sibling's activity may only ever remove a session that
/// is already incapable of running.
enum SameWorkspaceSessionSupersession {
    /// Grouping key for sessions competing for the same workspace slot, or `nil`
    /// when the session must not take part in supersession in either direction.
    nonisolated static func workspaceKey(for session: SessionState) -> String? {
        guard session.provider == .claude else { return nil }
        guard session.ingress != .nativeRuntime else { return nil }
        // Qwen command hooks do not expose the owning CLI PID, while their stable
        // session IDs explicitly support several sessions per workspace, so a Qwen
        // session neither supersedes a sibling nor gets superseded by one.
        guard !session.clientInfo.isQwenCodeClient else { return nil }
        let cwd = session.cwd
        guard !cwd.isEmpty else { return nil }
        return "\(session.provider.rawValue):\(cwd)"
    }

    /// How recently a session must have reported for that alone to prove it is
    /// still running.
    ///
    /// A hook that arrived seconds ago is direct evidence of liveness, and it is
    /// the *only* such evidence for an ingress that carries no pid: the Claude
    /// desktop app delivers `PreToolUse`/`PostToolUse` without one. Between two
    /// tool calls such a session also has no `.running` tail, so without this
    /// window both liveness checks come up empty for a session that is visibly
    /// working — and two live agents in one directory delete each other on every
    /// hook, each rebuilt from scratch by its next event.
    ///
    /// Sized like `pidIdentityTolerance` and for the same reason: erring long only
    /// delays cleanup of a replaced session by a minute, while erring short evicts
    /// sessions that are still working. A session that really did stop stays quiet,
    /// so the window closes on its own.
    nonisolated static let recentActivityLivenessWindow: TimeInterval = 60

    /// Whether a newer session sharing this session's workspace key may replace it.
    ///
    /// Only sessions that cannot still be running qualify. Recent activity, a live
    /// process, live execution evidence, a pending intervention, or an already
    /// ended result all mean the session stands on its own terms — two Claude
    /// instances running in the same directory is a supported setup, not a
    /// duplicate.
    ///
    /// Every liveness signal is bounded rather than absolute: recent activity ages
    /// out (`recentActivityLivenessWindow`), execution evidence expires
    /// (`SessionState.liveExecutionEvidenceMaxAge`), and the pid is checked for
    /// identity, not just existence. An unbounded signal latches the row into
    /// "working" forever, which is exactly what a crashed agent leaves behind.
    nonisolated static func canBeSuperseded(
        _ session: SessionState,
        now: Date = Date(),
        isProcessAlive: (Int, Date) -> Bool = SessionProcessLiveness.isAlive
    ) -> Bool {
        guard workspaceKey(for: session) != nil else { return false }
        // Ended sessions stay in the list until the user archives them.
        guard session.phase != .ended else { return false }
        guard !session.needsManualAttention else { return false }
        guard now.timeIntervalSince(session.lastActivity) >= recentActivityLivenessWindow else {
            return false
        }
        guard !session.hasLiveExecutionEvidence(asOf: now) else { return false }
        if let pid = session.pid, isProcessAlive(pid, session.lastActivity) { return false }
        return true
    }

    /// Drop sessions that a strictly newer sibling in the same workspace has
    /// superseded, keeping every session that could still be running.
    ///
    /// `SessionStore` archives these on the next new session and ends them on its
    /// liveness sweep; this keeps a restarted project from briefly showing two rows
    /// in between. Sessions that are merely older than a sibling are kept: several
    /// agents working in one directory is a supported setup, and collapsing them
    /// would make a single row flip between them on every hook event.
    nonisolated static func removingSupersededSessions(
        from sessions: [SessionState],
        now: Date = Date(),
        isProcessAlive: (Int, Date) -> Bool = SessionProcessLiveness.isAlive
    ) -> [SessionState] {
        var newestActivityByWorkspace: [String: Date] = [:]
        for session in sessions {
            guard let key = workspaceKey(for: session) else { continue }
            if let newestActivity = newestActivityByWorkspace[key] {
                newestActivityByWorkspace[key] = max(newestActivity, session.lastActivity)
            } else {
                newestActivityByWorkspace[key] = session.lastActivity
            }
        }

        guard !newestActivityByWorkspace.isEmpty else { return sessions }

        return sessions.filter { session in
            guard let key = workspaceKey(for: session),
                  let newestActivity = newestActivityByWorkspace[key],
                  newestActivity > session.lastActivity else {
                return true
            }
            return !canBeSuperseded(session, now: now, isProcessAlive: isProcessAlive)
        }
    }
}

/// Whether the process behind a session is still running.
enum SessionProcessLiveness {
    /// Slack on the "started after the session last spoke" comparison, absorbing
    /// clock adjustments and the gap between a process spawning and its first hook
    /// landing. Erring long only costs a delayed cleanup; erring short would evict
    /// sessions that are still working.
    nonisolated static let pidIdentityTolerance: TimeInterval = 60

    /// Whether *some* process currently holds `pid`.
    ///
    /// This says nothing about whether it is still the session's process — prefer
    /// `isAlive(_:lastSeenAlive:)` wherever a session is in hand.
    nonisolated static func isAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        // `EPERM` means the process exists but is owned by somebody else; only
        // `ESRCH` proves it is gone. Treating anything else as dead would evict
        // sessions that are still working.
        return errno != ESRCH
    }

    /// Whether `pid` is still the process that produced this session.
    ///
    /// A bare `kill(pid, 0)` is not proof of identity: macOS recycles pids, and
    /// Ping Island routinely stays up for days, so a dead agent's pid is eventually
    /// handed to an unrelated process. The session then looks permanently alive and
    /// is never superseded, never pruned, and never reaped — it just keeps
    /// animating as if it were working.
    ///
    /// The agent's own process necessarily already existed when it emitted the hook
    /// that produced `lastSeenAlive`, while a recycled pid belongs to a process that
    /// started after the original one died. A start time later than `lastSeenAlive`
    /// therefore proves reuse.
    nonisolated static func isAlive(_ pid: Int, lastSeenAlive: Date) -> Bool {
        guard isAlive(pid) else { return false }
        // Unreadable start time: keep the session, same as for `EPERM` above.
        guard let startedAt = startTime(ofPID: pid) else { return true }
        return startedAt <= lastSeenAlive.addingTimeInterval(pidIdentityTolerance)
    }

    /// Wall-clock start time of `pid`, or `nil` when no such process exists.
    nonisolated static func startTime(ofPID pid: Int) -> Date? {
        guard pid > 0 else { return nil }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
        // A vanished process reports success with a zero-length result.
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(started.tv_sec)
                + TimeInterval(started.tv_usec) / 1_000_000
        )
    }
}
