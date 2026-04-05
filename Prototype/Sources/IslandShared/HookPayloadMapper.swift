import Foundation

public enum HookPayloadMapper {
    public static func makeEnvelope(
        source: AgentProvider,
        arguments: [String],
        environment: [String: String],
        stdinData: Data
    ) -> BridgeEnvelope {
        let payload = BridgeCodec.readJSONObject(from: stdinData) ?? [:]
        let eventType = detectEventType(arguments: arguments, payload: payload)
        let terminalContext = makeTerminalContext(environment: environment, payload: payload)
        let sessionKey = detectSessionKey(payload: payload, environment: environment, provider: source)
        let status = detectStatus(eventType: eventType, payload: payload)
        let metadata = mergedMetadata(arguments: arguments, payload: payload)
        let intervention = detectIntervention(
            provider: source,
            eventType: eventType,
            sessionKey: sessionKey,
            payload: payload
        )

        return BridgeEnvelope(
            provider: source,
            eventType: eventType,
            sessionKey: sessionKey,
            title: detectTitle(payload: payload),
            preview: detectPreview(payload: payload),
            cwd: detectCWD(payload: payload, environment: environment),
            status: status,
            terminalContext: terminalContext,
            intervention: intervention,
            expectsResponse: intervention != nil,
            metadata: metadata
        )
    }

    public static func stdoutPayload(
        for provider: AgentProvider,
        decision: InterventionDecision,
        eventType: String
    ) -> String {
        switch provider {
        case .claude:
            switch decision {
            case .approve:
                return #"""
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
                """#
            case .approveForSession:
                return #"""
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
                """#
            case .deny, .cancel:
                return #"""
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Island"}}}
                """#
            case .answer(let answers):
                return String(data: (try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            }
        case .codex:
            switch decision {
            case .approve:
                return #"{"decision":"accept"}"#
            case .approveForSession:
                return #"{"decision":"acceptForSession"}"#
            case .deny:
                return #"{"decision":"decline"}"#
            case .cancel:
                return #"{"decision":"cancel"}"#
            case .answer(let answers):
                return String(data: (try? JSONSerialization.data(withJSONObject: ["answers": answers], options: [.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            }
        }
    }

    private static func detectEventType(arguments: [String], payload: [String: Any]) -> String {
        if let explicit = payload["hook_event_name"] as? String { return explicit }
        if let explicit = payload["event"] as? String { return explicit }
        if let explicit = payload["type"] as? String { return explicit }
        if let index = arguments.firstIndex(of: "--event"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        if payload["questions"] != nil { return "UserInputRequest" }
        if payload["tool_input"] != nil || payload["tool_name"] != nil { return "PreToolUse" }
        return "UnknownEvent"
    }

    private static func detectSessionKey(
        payload: [String: Any],
        environment: [String: String],
        provider: AgentProvider
    ) -> String {
        let candidates = [
            payload["session_id"] as? String,
            payload["sessionId"] as? String,
            payload["thread_id"] as? String,
            payload["threadId"] as? String,
            environment["CLAUDE_SESSION_ID"],
            environment["CODEX_THREAD_ID"],
            environment["ITERM_SESSION_ID"],
            environment["TERM_SESSION_ID"],
            environment["TTY"]
        ]
        if let value = candidates.compactMap({ $0 }).first, !value.isEmpty {
            return "\(provider.rawValue):\(value)"
        }
        let cwd = detectCWD(payload: payload, environment: environment) ?? "unknown"
        return "\(provider.rawValue):\(cwd)"
    }

    private static func detectStatus(eventType: String, payload: [String: Any]) -> SessionStatus? {
        if let text = payload["status"] as? String {
            return mapStatusString(text)
        }
        let lowered = eventType.lowercased()
        if lowered.contains("permission") || lowered.contains("approval") {
            return SessionStatus(kind: .waitingForApproval)
        }
        if lowered.contains("question") || lowered.contains("userinput") {
            return SessionStatus(kind: .waitingForInput)
        }
        if lowered.contains("pretool") {
            return SessionStatus(kind: .runningTool)
        }
        if lowered.contains("posttool") {
            return SessionStatus(kind: .active)
        }
        if lowered.contains("stop") || lowered.contains("end") {
            return SessionStatus(kind: .completed)
        }
        if lowered.contains("compact") {
            return SessionStatus(kind: .compacting)
        }
        if lowered.contains("start") || lowered.contains("submit") {
            return SessionStatus(kind: .thinking)
        }
        return SessionStatus(kind: .active)
    }

    private static func mapStatusString(_ string: String) -> SessionStatus {
        let lowered = string.lowercased()
        switch lowered {
        case let text where text.contains("approval"):
            return SessionStatus(kind: .waitingForApproval, detail: string)
        case let text where text.contains("input") || text.contains("question"):
            return SessionStatus(kind: .waitingForInput, detail: string)
        case let text where text.contains("tool"):
            return SessionStatus(kind: .runningTool, detail: string)
        case let text where text.contains("think"):
            return SessionStatus(kind: .thinking, detail: string)
        case let text where text.contains("compact"):
            return SessionStatus(kind: .compacting, detail: string)
        case let text where text.contains("done") || text.contains("idle"):
            return SessionStatus(kind: .completed, detail: string)
        case let text where text.contains("error") || text.contains("fail"):
            return SessionStatus(kind: .error, detail: string)
        default:
            return SessionStatus(kind: .active, detail: string)
        }
    }

    private static func detectTitle(payload: [String: Any]) -> String? {
        [
            payload["title"] as? String,
            payload["session_title"] as? String,
            payload["tool_name"] as? String,
            payload["hook_event_name"] as? String
        ].compactMap { $0 }.first
    }

    private static func detectPreview(payload: [String: Any]) -> String? {
        if let toolName = payload["tool_name"] as? String {
            if let input = summarizeValue(payload["tool_input"]) {
                return "\(toolName) \(input)"
            }
            return toolName
        }
        return [
            payload["prompt"] as? String,
            payload["message"] as? String,
            payload["last_assistant_message"] as? String,
            payload["command"] as? String,
            summarizeValue(payload["tool_input"])
        ].compactMap { $0 }.first
    }

    private static func detectCWD(payload: [String: Any], environment: [String: String]) -> String? {
        [
            payload["cwd"] as? String,
            payload["workspace"] as? String,
            environment["PWD"]
        ].compactMap { $0 }.first
    }

    private static func makeTerminalContext(environment: [String: String], payload: [String: Any]) -> TerminalContext {
        TerminalContext(
            terminalProgram: environment["TERM_PROGRAM"],
            terminalBundleID: environment["__CFBundleIdentifier"] ?? payload["terminalBundleID"] as? String,
            iTermSessionID: environment["ITERM_SESSION_ID"],
            terminalSessionID: environment["TERM_SESSION_ID"],
            tty: environment["TTY"],
            currentDirectory: detectCWD(payload: payload, environment: environment),
            tmuxSession: environment["TMUX"],
            tmuxPane: environment["TMUX_PANE"]
        )
    }

    private static func detectIntervention(
        provider: AgentProvider,
        eventType: String,
        sessionKey: String,
        payload: [String: Any]
    ) -> InterventionRequest? {
        if let questions = payload["questions"] as? [[String: Any]], !questions.isEmpty {
            let options = questions.flatMap { question -> [InterventionOption] in
                let baseID = (question["id"] as? String) ?? UUID().uuidString
                let entries = question["options"] as? [[String: Any]] ?? []
                if entries.isEmpty {
                    return [InterventionOption(id: baseID, title: question["question"] as? String ?? "Answer")]
                }
                return entries.enumerated().map { index, option in
                    InterventionOption(
                        id: "\(baseID):\(index)",
                        title: option["label"] as? String ?? "Option \(index + 1)",
                        detail: option["description"] as? String
                    )
                }
            }
            return InterventionRequest(
                sessionID: sessionKey,
                kind: .question,
                title: provider == .claude ? "Claude needs input" : "Codex needs input",
                message: (questions.first?["question"] as? String) ?? "Answer required",
                options: options,
                rawContext: flattenMetadata(payload: payload)
            )
        }

        let lowered = eventType.lowercased()
        guard lowered.contains("permission") || lowered.contains("approval") else {
            return nil
        }
        let message = (payload["reason"] as? String)
            ?? (payload["tool_name"] as? String)
            ?? (payload["command"] as? String)
            ?? "The agent is waiting for permission."
        return InterventionRequest(
            sessionID: sessionKey,
            kind: .approval,
            title: provider == .claude ? "Claude needs approval" : "Codex needs approval",
            message: message,
            options: [
                InterventionOption(id: "approve", title: "Allow Once"),
                InterventionOption(id: "approveForSession", title: "Allow for Session"),
                InterventionOption(id: "deny", title: "Deny")
            ],
            rawContext: flattenMetadata(payload: payload)
        )
    }

    private static func mergedMetadata(arguments: [String], payload: [String: Any]) -> [String: String] {
        var metadata = flattenMetadata(payload: payload)
        for (key, value) in argumentMetadata(arguments: arguments) where metadata[key] == nil {
            metadata[key] = value
        }
        return metadata
    }

    private static func argumentMetadata(arguments: [String]) -> [String: String] {
        let mappings: [String: String] = [
            "--client-kind": "client_kind",
            "--client-name": "client_name",
            "--client-bundle-id": "client_bundle_id",
            "--client-origin": "client_origin",
            "--client-originator": "client_originator",
            "--thread-source": "thread_source",
            "--launch-url": "launch_url"
        ]

        var metadata: [String: String] = [:]
        for (flag, key) in mappings {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                continue
            }

            let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                metadata[key] = value
            }
        }

        return metadata
    }

    private static func flattenMetadata(payload: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in payload {
            guard let stringValue = summarizeValue(value) else { continue }
            result[key] = stringValue
        }
        return result
    }

    private static func summarizeValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            guard JSONSerialization.isValidJSONObject(array),
                  let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return string
        case let object as [String: Any]:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return string
        default:
            return nil
        }
    }
}
