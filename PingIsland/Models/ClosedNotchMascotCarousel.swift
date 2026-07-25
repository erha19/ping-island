import Foundation

/// Rotates the closed-notch silhouette across live agents so multiple working
/// sessions remain visible without widening the island.
enum ClosedNotchMascotCarousel {
    static let interval: TimeInterval = 2.0

    /// Sessions eligible for closed-notch identity rotation.
    /// Order: prompt attention first, then active work (newest activity first).
    static func sessions(from instances: [SessionState]) -> [SessionState] {
        var seen = Set<String>()
        var ordered: [SessionState] = []

        func append(_ session: SessionState) {
            guard seen.insert(session.sessionId).inserted else { return }
            ordered.append(session)
        }

        instances
            .filter(\.needsPromptNotification)
            .sorted(by: attentionSort)
            .forEach(append)

        instances
            .filter { $0.phase.isActive }
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .forEach(append)

        if ordered.isEmpty, let fallback = IslandMascotResolver.sourceSession(from: instances) {
            ordered.append(fallback)
        }

        return ordered
    }

    static func index(sessionCount: Int, at date: Date, interval: TimeInterval = Self.interval) -> Int {
        guard sessionCount > 1 else { return 0 }
        let tick = Int(floor(date.timeIntervalSinceReferenceDate / interval))
        let modulo = tick % sessionCount
        return modulo >= 0 ? modulo : modulo + sessionCount
    }

    static func currentSession(from instances: [SessionState], at date: Date) -> SessionState? {
        let sessions = sessions(from: instances)
        guard !sessions.isEmpty else { return nil }
        return sessions[index(sessionCount: sessions.count, at: date)]
    }

    /// Per-session status for the currently shown silhouette.
    static func status(for session: SessionState) -> MascotStatus {
        MascotStatus(session: session)
    }

    private static func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        (lhs.attentionRequestedAt ?? lhs.lastActivity) > (rhs.attentionRequestedAt ?? rhs.lastActivity)
    }
}
