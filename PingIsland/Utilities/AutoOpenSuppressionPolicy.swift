import Foundation

/// Decides whether a session that just started needing attention is allowed to
/// auto-expand the island panel.
///
/// `smartSuppression` has always suppressed the panel while a terminal window is
/// visible on the current space. That covers the case where the user watches the
/// agent work, but not the case where the user is sitting in front of the machine
/// in *another* app: an agent running in auto mode keeps emitting approval
/// requests, and each one re-opened the panel even though the user had not walked
/// away. This policy widens "user is present" to include recent keyboard/mouse
/// activity, so the island only interrupts once the user has actually stepped
/// away.
///
/// Attention state itself is untouched — the notch status hint and the attention
/// sound still fire; only the automatic expansion is skipped.
enum AutoOpenSuppressionPolicy {
    /// How long the user must be away from keyboard and mouse before the island
    /// is allowed to auto-expand again.
    static let userActiveIdleThreshold: TimeInterval = 30

    nonisolated static func shouldSuppressAutoOpen(
        smartSuppressionEnabled: Bool,
        isTerminalVisible: Bool,
        suppressWhileUserActive: Bool,
        idleSeconds: TimeInterval
    ) -> Bool {
        guard smartSuppressionEnabled else { return false }
        if isTerminalVisible { return true }
        guard suppressWhileUserActive else { return false }
        return idleSeconds < userActiveIdleThreshold
    }
}
