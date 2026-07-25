import Darwin
import Foundation

/// Canonical Claude-style hook event names.
///
/// Cursor (and some other hosts) emit camelCase names such as `stop` /
/// `postToolUse`. Normalize at the socket boundary so SessionStore and
/// status mapping can keep using the Claude PascalCase contracts.
enum HookEventName {
    static func normalized(_ raw: String) -> String {
        switch raw {
        case "Stop", "UserPromptSubmit", "PreToolUse", "PostToolUse",
             "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop",
             "PreCompact", "Notification", "PermissionRequest":
            return raw
        default:
            break
        }

        switch raw.lowercased() {
        case "stop", "stopfailure":
            return "Stop"
        case "beforesubmitprompt", "userpromptsubmit":
            return "UserPromptSubmit"
        case "pretooluse":
            return "PreToolUse"
        case "posttooluse":
            return "PostToolUse"
        case "sessionstart":
            return "SessionStart"
        case "sessionend":
            return "SessionEnd"
        case "subagentstart":
            return "SubagentStart"
        case "subagentstop":
            return "SubagentStop"
        case "precompact":
            return "PreCompact"
        case "notification":
            return "Notification"
        case "permissionrequest":
            return "PermissionRequest"
        default:
            return raw
        }
    }

    /// Shared status mapping used by HookSocketServer (case-safe for Cursor).
    static func mapStatus(
        eventType: String,
        bridgeStatusKind: String?,
        notificationType: String?,
        provider: SessionProvider
    ) -> String {
        let event = normalized(eventType)
        _ = provider

        if event == "Notification", notificationType == "idle_prompt" {
            return "waiting_for_input"
        }

        switch bridgeStatusKind {
        case "waitingForApproval":
            return "waiting_for_approval"
        case "waitingForInput":
            return "waiting_for_input"
        case "runningTool":
            return "running_tool"
        case "compacting":
            return "compacting"
        case "completed":
            return "ended"
        case "notification":
            return "notification"
        case "interrupted":
            return "waiting_for_input"
        case "idle":
            return "idle"
        default:
            break
        }

        switch event {
        case "SessionEnd":
            return "ended"
        case "SessionStart", "SubagentStop":
            return "waiting_for_input"
        case "Stop":
            // Turn finished; keep the session alive for the next prompt.
            return "waiting_for_input"
        case "UserPromptSubmit", "PostToolUse":
            return "processing"
        case "PreToolUse":
            return "running_tool"
        case "PreCompact":
            return "compacting"
        case "Notification":
            return "notification"
        default:
            return "processing"
        }
    }
}

/// Evidence used when deciding whether an apparent idle transition should keep
/// an in-flight `.processing` / `.compacting` phase.
enum SessionExecutionEvidence {
    static func hasLiveExecution(_ session: SessionState) -> Bool {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .thinking:
                // Persisted thinking text is historical, not an in-flight spinner.
                continue
            case .toolCall(let tool):
                if tool.status == .running || tool.status == .waitingForApproval {
                    return true
                }
                continue
            case .assistant, .user, .interrupted:
                return false
            }
        }
        return false
    }
}

/// Recovers Claude-family sessions that stay `.processing` after Stop is missed
/// (common for Cursor IDE hosts whose process PID remains alive).
enum StuckActiveSessionRecovery {
    /// No tracked PID: demote sooner once hooks go quiet.
    static let missingProcessIdleTimeout: TimeInterval = 30
    /// Live PID (often the IDE): wait longer before assuming the turn finished.
    static let liveProcessIdleTimeout: TimeInterval = 3 * 60

    enum Decision: Equatable {
        case keep
        case demoteToWaitingForInput
        case endSession
    }

    static func decision(
        for session: SessionState,
        now: Date = Date(),
        isProcessAlive: (Int) -> Bool = { pid in
            Darwin.kill(pid_t(pid), 0) == 0
        }
    ) -> Decision {
        guard session.provider == .claude else { return .keep }
        guard session.ingress != .nativeRuntime else { return .keep }
        guard session.phase.isActive else { return .keep }
        guard !session.needsManualAttention else { return .keep }

        let idleSeconds = now.timeIntervalSince(session.lastActivity)

        if let pid = session.pid, pid > 0 {
            if !isProcessAlive(pid) {
                return idleSeconds >= missingProcessIdleTimeout ? .endSession : .keep
            }
            guard idleSeconds >= liveProcessIdleTimeout else { return .keep }
            guard !SessionExecutionEvidence.hasLiveExecution(session) else { return .keep }
            return .demoteToWaitingForInput
        }

        guard idleSeconds >= missingProcessIdleTimeout else { return .keep }
        guard !SessionExecutionEvidence.hasLiveExecution(session) else { return .keep }
        return .demoteToWaitingForInput
    }
}

