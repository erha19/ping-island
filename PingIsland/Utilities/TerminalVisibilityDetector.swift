//
//  TerminalVisibilityDetector.swift
//  PingIsland
//
//  Detects if terminal windows are visible on current space
//

import AppKit
import CoreGraphics

struct TerminalVisibilityDetector {
    /// Check if any terminal window is visible on the current space
    static func isTerminalVisibleOnCurrentSpace() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }

            if TerminalAppRegistry.isTerminal(ownerName) {
                return true
            }
        }

        return false
    }

    /// Check if the frontmost (active) application is a terminal
    static func isTerminalFrontmost() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmostApp.bundleIdentifier else {
            return false
        }

        return TerminalAppRegistry.isTerminalBundle(bundleId)
    }

    /// Whether the app recorded as a session's host is frontmost right now.
    ///
    /// Synchronous counterpart to `isSessionHostFocused` for callers that cannot await,
    /// such as the completion-notification queues. It skips the tmux pane check and the
    /// pid fallback, so prefer `isSessionHostFocused` wherever awaiting is possible.
    ///
    /// - Parameter hostBundleIdentifier: Host recorded on the session.
    /// - Returns: `true` when that host is the frontmost app.
    static func isSessionHostFrontmost(hostBundleIdentifier: String?) -> Bool {
        hostBundleMatchesFrontmost(
            hostBundleIdentifier: hostBundleIdentifier,
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    /// Whether the app hosting a session is frontmost.
    ///
    /// Sessions do not always carry a pid: an agent running as an IDE extension reports
    /// no pid in its hook metadata, which leaves every pid-based check unreachable. The
    /// host's bundle identifier is recorded on the session either way, so matching that
    /// against the frontmost app answers the question without needing a live process.
    /// Process resolution stays as a fallback for tmux panes and plain terminals.
    ///
    /// - Parameters:
    ///   - hostBundleIdentifier: Bundle identifier of the terminal or IDE hosting the
    ///     session, from `SessionClientInfo.hostBundleIdentifier`.
    ///   - sessionPid: The session's pid when one is known.
    /// - Returns: `true` when the user is looking at the app hosting this session.
    static func isSessionHostFocused(hostBundleIdentifier: String?, sessionPid: Int?) async -> Bool {
        if isSessionHostFrontmost(hostBundleIdentifier: hostBundleIdentifier) {
            /// Inside tmux the window can be frontmost while the session's pane is not.
            if let sessionPid,
               ProcessTreeBuilder.shared.isInTmux(pid: sessionPid, tree: ProcessTreeBuilder.shared.buildTree()) {
                return await TmuxTargetFinder.shared.isSessionPaneActive(claudePid: sessionPid)
            }
            return true
        }

        /// A recorded host that is not frontmost is not conclusive on its own, since the
        /// field can be stale, so fall through to process resolution when a pid exists.
        guard let sessionPid else {
            return false
        }
        return await isSessionFocused(sessionPid: sessionPid)
    }

    /// Focus answer for a session, honouring whether the user opted into host-focus
    /// resolution.
    ///
    /// With the opt-in off this keeps the original pid-only behaviour exactly, including
    /// treating a session without a pid as unfocused, so callers that predate the
    /// setting are unchanged until the user asks for the new logic.
    ///
    /// - Parameters:
    ///   - hostBundleIdentifier: Host recorded on the session.
    ///   - sessionPid: The session's pid when one is known.
    ///   - hostFocusResolutionEnabled: Whether the user opted in.
    /// - Returns: `true` when the user is looking at this session.
    static func isSessionFocused(
        hostBundleIdentifier: String?,
        sessionPid: Int?,
        hostFocusResolutionEnabled: Bool
    ) async -> Bool {
        guard hostFocusResolutionEnabled else {
            guard let sessionPid else { return false }
            return await isSessionFocused(sessionPid: sessionPid)
        }
        return await isSessionHostFocused(
            hostBundleIdentifier: hostBundleIdentifier,
            sessionPid: sessionPid
        )
    }

    /// Whether a session's recorded host bundle identifier denotes the frontmost app.
    ///
    /// Helper bundles fold onto their host, so an IDE reporting a helper as frontmost
    /// still matches the host recorded on the session.
    ///
    /// - Parameters:
    ///   - hostBundleIdentifier: Host recorded on the session.
    ///   - frontmostBundleIdentifier: Bundle identifier currently frontmost.
    /// - Returns: `true` when both resolve to the same host bundle.
    nonisolated static func hostBundleMatchesFrontmost(
        hostBundleIdentifier: String?,
        frontmostBundleIdentifier: String?
    ) -> Bool {
        guard let hostBundleIdentifier = hostBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostBundleIdentifier.isEmpty,
              let frontmostBundleIdentifier = frontmostBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !frontmostBundleIdentifier.isEmpty else {
            return false
        }

        let normalizedHost = TerminalAppRegistry.normalizedHostBundleIdentifier(for: hostBundleIdentifier)

        /// Only recognised terminals and IDEs count as hosts. This also keeps the Island
        /// itself out: when it is frontmost the user is looking at the Island, which is
        /// exactly when an approval should be shown rather than withheld.
        guard TerminalAppRegistry.isTerminalBundle(normalizedHost) else {
            return false
        }

        return normalizedHost.lowercased()
            == TerminalAppRegistry.normalizedHostBundleIdentifier(for: frontmostBundleIdentifier).lowercased()
    }

    /// Check if a tracked session is currently focused (user is looking at it)
    /// - Parameter sessionPid: The PID of the Claude process
    /// - Returns: true if the session's terminal is frontmost and (for tmux) the pane is active
    static func isSessionFocused(sessionPid: Int) async -> Bool {
        // If no terminal is frontmost, session is definitely not focused
        guard isTerminalFrontmost() else {
            return false
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        let isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: sessionPid, tree: tree)

        if isInTmux {
            // For tmux sessions, check if the session's pane is active
            return await TmuxTargetFinder.shared.isSessionPaneActive(claudePid: sessionPid)
        } else {
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
                return false
            }
            let frontmostPid = Int(frontmostApp.processIdentifier)

            /// Ownership of the session's process chain is the reliable signal. Name
            /// matching cannot answer this for IDE-hosted terminals: the agent binary
            /// can sit inside the IDE's own extension directory, so it matches ahead of
            /// the app, as do the IDE's helper processes.
            if ProcessTreeBuilder.shared.isAncestor(frontmostPid, of: sessionPid, tree: tree) {
                return true
            }

            /// Fall back to name-based resolution for chains the snapshot cannot
            /// connect, such as a shell re-parented away from its terminal.
            let sessionInfo = tree[sessionPid]
            let sessionTerminalPid =
                sessionInfo?.tty.flatMap { ProcessTreeBuilder.shared.findTerminalPid(forTTY: $0, tree: tree) } ??
                ProcessTreeBuilder.shared.findTerminalPid(forProcess: sessionPid, tree: tree)

            return sessionTerminalPid == frontmostPid
        }
    }
}
