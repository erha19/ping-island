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

    /// Closed-notch mascot behavior mirrors the representative session:
    /// active work animates, idle/ended sessions rest, and attention states warn.
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
        case .idle, .ended:
            return .idle
        case .processing, .compacting:
            return .working
        case .waitingForInput, .waitingForApproval:
            return .warning
        }
    }
}
