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

enum IslandPresentationActivationPolicy: Equatable {
    case interactive
    case silent

    var activatesApplication: Bool {
        self == .interactive
    }

    var presentsAutomaticContent: Bool {
        self == .interactive
    }
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
        if let prompt = sessions
            .filter(\.needsPromptNotification)
            .sorted(by: {
                ($0.attentionRequestedAt ?? $0.lastActivity) > ($1.attentionRequestedAt ?? $1.lastActivity)
            })
            .first {
            return prompt
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
    /// Session that owns the closed-notch silhouette.
    /// Prefer real prompts (approval / question) over live work, and live work over
    /// turn-ended `waitingForInput` so a just-finished agent cannot stick on screen
    /// while another agent is still processing.
    static func sourceSession(from sessions: [SessionState]) -> SessionState? {
        if let prompt = sessions
            .filter(\.needsPromptNotification)
            .sorted(by: attentionSort)
            .first {
            return prompt
        }

        if let active = sessions
            .filter({ $0.phase.isActive })
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first {
            return active
        }

        return sessions
            .filter { $0.phase == .waitingForInput || $0.needsManualAttention }
            .sorted(by: attentionSort)
            .first
    }

    private static func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        (lhs.attentionRequestedAt ?? lhs.lastActivity) > (rhs.attentionRequestedAt ?? rhs.lastActivity)
    }
}
