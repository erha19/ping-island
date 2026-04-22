import Foundation

enum IslandExpandedSurface: Equatable {
    case docked
    case floating
}

enum IslandExpandedTrigger: Equatable {
    case click
    case hover
    case notification
    case pinnedList
}

enum IslandExpandedRoute: Equatable {
    case sessionList
    case hoverDashboard
    case attentionNotification(SessionState)
    case completionNotification(SessionCompletionNotification)
    case chat(SessionState)
}

enum IslandExpandedRouteResolver {
    nonisolated static func resolve(
        surface: IslandExpandedSurface,
        trigger: IslandExpandedTrigger,
        contentType: NotchContentType,
        sessions: [SessionState],
        activeCompletionNotification: SessionCompletionNotification? = nil
    ) -> IslandExpandedRoute {
        if case .chat(let session) = contentType {
            return .chat(session)
        }

        switch (surface, trigger) {
        case (.docked, .notification):
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            return .sessionList
        case (.docked, .hover), (.floating, .hover):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .hoverDashboard
        case (.floating, .notification):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            return .hoverDashboard
        case (_, .click), (_, .pinnedList):
            return .sessionList
        }
    }

    nonisolated static func orderedSessions(from sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { $0.shouldSortBeforeInQueue($1) }
    }

    nonisolated static func activePreviewSessions(from sessions: [SessionState]) -> [SessionState] {
        orderedSessions(from: sessions).filter(\.phase.isActive)
    }

    nonisolated static func highestPriorityAttentionSession(from sessions: [SessionState]) -> SessionState? {
        orderedSessions(from: sessions)
            .filter { $0.needsApprovalResponse || $0.needsQuestionResponse }
            .sorted(by: attentionSort)
            .first
    }

    nonisolated private static func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastUserMessageDate ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastUserMessageDate ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}
