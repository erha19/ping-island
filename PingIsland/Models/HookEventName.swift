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
