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

    /// Whether a newer session sharing this session's workspace key may replace it.
    ///
    /// Only sessions that cannot still be running qualify. A live process, live
    /// execution evidence, a pending intervention, or an already ended result all
    /// mean the session stands on its own terms — two Claude instances running in
    /// the same directory is a supported setup, not a duplicate.
    nonisolated static func canBeSuperseded(
        _ session: SessionState,
        isProcessAlive: (Int) -> Bool = SessionProcessLiveness.isAlive
    ) -> Bool {
        guard workspaceKey(for: session) != nil else { return false }
        // Ended sessions stay in the list until the user archives them.
        guard session.phase != .ended else { return false }
        guard !session.needsManualAttention else { return false }
        guard !session.hasLiveExecutionEvidence else { return false }
        if let pid = session.pid, isProcessAlive(pid) { return false }
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
        isProcessAlive: (Int) -> Bool = SessionProcessLiveness.isAlive
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
            return !canBeSuperseded(session, isProcessAlive: isProcessAlive)
        }
    }
}

/// Whether the process behind a session is still running.
enum SessionProcessLiveness {
    nonisolated static func isAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        // `EPERM` means the process exists but is owned by somebody else; only
        // `ESRCH` proves it is gone. Treating anything else as dead would evict
        // sessions that are still working.
        return errno != ESRCH
    }
}
