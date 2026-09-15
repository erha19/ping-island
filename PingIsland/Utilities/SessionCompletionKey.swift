import Foundation

/// Stable identity for one completed turn.
///
/// Phase transitions are deliberately excluded: app-server polling can replay an
/// old idle snapshot after a session has returned to processing. Use the provider
/// turn ID when available, or the hook completion sequence when it is not.
nonisolated struct SessionCompletionKey: Hashable, Sendable {
    let sessionId: String
    let turnId: String

    nonisolated static func make(for session: SessionState) -> SessionCompletionKey? {
        guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else {
            return nil
        }

        let stableTurnId: String
        if let latestTurnId = normalized(session.latestTurnId) {
            stableTurnId = latestTurnId
        } else {
            stableTurnId = "completion-\(session.completionSequence)"
        }

        return SessionCompletionKey(
            sessionId: session.sessionId,
            turnId: stableTurnId
        )
    }

    private nonisolated static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
