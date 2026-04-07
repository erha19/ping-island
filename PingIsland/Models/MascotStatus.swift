import Foundation

/// Mascot animation states
enum MascotStatus: String, Codable, CaseIterable, Sendable {
    case idle = "idle"           // 空闲状态
    case working = "working"    // 工作中
    case warning = "warning"    // 告警/等待审批
    
    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .working: return "工作中"
        case .warning: return "等待审批"
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
}