import Foundation

/// Decides whether a given session should contribute to the
/// `attentionRequired` notification-sound edge set.
///
/// Two UI sites — `NotchView` and `DetachedIslandWindowController` — use this
/// to compute the `attentionSessions` set whose membership delta drives the
/// sound. Sessions in always-allow mode (`autoApprovePermissions == true`)
/// are excluded so auto-approved `PermissionRequest` events do not chime,
/// matching the existing `SoundManager.handleEvent` gate in
/// `SessionMonitor.handleIncomingHookEvent`.
enum SessionAttentionSoundEvaluator {
    /// Whether this session is currently eligible to fire an
    /// `attentionRequired` sound on the phase-edge channel.
    static func shouldContributeToAttentionSoundEdge(_ session: SessionState) -> Bool {
        guard !session.autoApprovePermissions else { return false }
        return session.needsApprovalResponse
            || (session.phase == .waitingForInput && session.intervention != nil)
    }
}
