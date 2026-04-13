import Foundation

enum SessionProvider {
    case codex
    case claude
    case copilot
}

enum SessionClientBrand {
    case codebuddy
    case codex
    case gemini
    case qwen
    case opencode
    case qoder
    case copilot
    case claude
    case neutral
}

struct SessionClientProfile {
    let id: String
}

struct SessionClientInfo {
    var brand: SessionClientBrand = .neutral

    func resolvedProfile(for provider: SessionProvider) -> SessionClientProfile? {
        nil
    }
}

enum SessionPhase {
    case idle
    case ended
    case waitingForApproval
    case waitingForInput
    case processing
    case compacting

    var isActive: Bool {
        switch self {
        case .processing, .compacting, .waitingForApproval, .waitingForInput:
            return true
        case .idle, .ended:
            return false
        }
    }
}

struct SessionState {
    var needsManualAttention = false
    var phase: SessionPhase = .idle
    var clientInfo: SessionClientInfo = .init()
    var provider: SessionProvider = .claude
}

enum AppLocalization {
    static func format(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: format, arguments: arguments)
    }
}
