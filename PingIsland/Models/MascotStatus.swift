import Foundation

/// Mascot animation states
enum MascotStatus: String, Codable, CaseIterable, Sendable {
    case idle = "idle"
    case working = "working"
    case warning = "warning"
    case dragging = "dragging"
    
    var displayName: String {
        switch self {
        case .idle: return "空闲中"
        case .working: return "运行中"
        case .warning: return "警告状态"
        case .dragging: return "拖拽中"
        }
    }
}

/// Extension to map session status to mascot status
extension MascotStatus {
    /// Convert from session phase to mascot status
    init(from sessionPhase: SessionPhase) {
        switch sessionPhase {
        case .idle, .ended:
            self = .idle
        case .waitingForApproval, .waitingForInput:
            self = .warning
        case .processing, .compacting:
            self = .working
        }
    }

    /// Closed-notch mascot behavior is intentionally more "alive" than row-level status:
    /// once a warning is handled, any still-live session should return to the active animation
    /// until it actually ends or disappears from the compact surface.
    static func closedNotchStatus(
        representativePhase: SessionPhase?,
        hasPendingPermission: Bool,
        hasHumanIntervention: Bool
    ) -> MascotStatus {
        if hasPendingPermission || hasHumanIntervention {
            return .warning
        }

        guard let representativePhase else {
            return .idle
        }

        switch representativePhase {
        case .ended:
            return .idle
        case .idle, .processing, .waitingForInput, .waitingForApproval, .compacting:
            return .working
        }
    }
}
