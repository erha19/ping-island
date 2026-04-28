import CoreGraphics
import Foundation

enum IslandPresentationMode: Equatable {
    case docked
    case detached
}

enum IslandOpenedPresentationStyle: Equatable {
    case docked
    case detached
}

enum DetachedIslandDisplayMode: Equatable {
    case compact
    case hoverExpanded
}

enum DetachedIslandBubbleState: Equatable {
    case hidden
    case hoverPreview
    case pinned
}

enum IslandDetachmentSource: Equatable {
    case closed
    case opened
}

struct IslandDetachmentRequest: Equatable {
    let source: IslandDetachmentSource
    let dragStartScreenLocation: CGPoint
    let currentScreenLocation: CGPoint
}

struct IslandDetachmentPayload: Equatable {
    let contentType: NotchContentType
    let dragStartScreenLocation: CGPoint
    let initialCursorScreenLocation: CGPoint
    let cursorWindowOffset: CGPoint
}

struct IslandDetachmentGestureGate {
    static let defaultThreshold: CGFloat = 20
    static let defaultLongPressDuration: TimeInterval = 0.35

    static func qualifies(
        start startLocation: CGPoint,
        current currentLocation: CGPoint,
        hasSatisfiedLongPress: Bool,
        threshold: CGFloat = defaultThreshold
    ) -> Bool {
        guard hasSatisfiedLongPress else { return false }
        let horizontalDistance = abs(currentLocation.x - startLocation.x)
        let downwardDistance = startLocation.y - currentLocation.y
        return downwardDistance >= threshold && downwardDistance > horizontalDistance
    }
}

struct IslandDetachedContentResolver {
    static func resolve(
        status: NotchStatus,
        openReason: NotchOpenReason,
        contentType: NotchContentType,
        sessions: [SessionState]
    ) -> NotchContentType {
        guard shouldNormalizeContent(
            status: status,
            openReason: openReason
        ) else {
            return contentType
        }

        guard let preferredSession = preferredSession(from: sessions) else {
            return .instances
        }

        return .chat(preferredSession)
    }

    static func preferredSession(from sessions: [SessionState]) -> SessionState? {
        if let attention = sessions
            .filter(\.needsManualAttention)
            .sorted(by: { ($0.attentionRequestedAt ?? $0.lastActivity) > ($1.attentionRequestedAt ?? $1.lastActivity) })
            .first {
            return attention
        }

        if let active = sessions.filter({ $0.phase.isActive })
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first {
            return active
        }

        return nil
    }

    private static func shouldNormalizeContent(
        status: NotchStatus,
        openReason: NotchOpenReason
    ) -> Bool {
        guard status == .opened else { return true }

        switch openReason {
        case .hover, .notification:
            return true
        case .click, .boot, .unknown:
            return false
        }
    }
}

enum IslandMascotResolver {
    nonisolated static func sourceSession(from sessions: [SessionState]) -> SessionState? {
        ClosedNotchActivityResolver.representativeSession(from: sessions)
    }
}

enum ClosedNotchActivityResolver {
    nonisolated static func hasActionableAttention(_ session: SessionState) -> Bool {
        session.needsApprovalResponse || session.intervention != nil
    }

    nonisolated static func activeCount(from sessions: [SessionState]) -> Int {
        sessions.filter { $0.phase.isActive }.count
    }

    nonisolated static func representativeSession(from sessions: [SessionState]) -> SessionState? {
        if let attention = sessions
            .filter(hasActionableAttention)
            .sorted(by: activitySort)
            .first {
            return attention
        }

        return sessions
            .filter { $0.phase.isActive }
            .sorted(by: activitySort)
            .first
    }

    nonisolated private static func activitySort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}
