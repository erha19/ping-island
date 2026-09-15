import Foundation

/// Decides whether a given session should contribute to the
/// `attentionRequired` notification-sound edge set.
///
/// The single `SessionMonitor` sound edge tracker uses this per-session
/// predicate. Disconnected sessions and sessions in always-allow mode must not
/// chime for stale or automatically handled permission requests.
enum SessionAttentionSoundEvaluator {
    /// Whether this session is currently eligible to fire an
    /// `attentionRequired` sound on the phase-edge channel.
    nonisolated static func shouldContributeToAttentionSoundEdge(_ session: SessionState) -> Bool {
        guard session.connectionState == .connected, !session.autoApprovePermissions else { return false }
        return session.needsApprovalResponse
            || session.needsQuestionResponse
            || session.suppressInAppPromptControls
    }
}
