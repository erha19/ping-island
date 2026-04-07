import Foundation

public enum HookPayloadMapper {
    private static let questionToolNames: Set<String> = [
        "askuserquestion",
        "askfollowupquestion"
    ]

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
        let metadata = mergedMetadata(arguments: arguments, payload: payload)
        let clientKind = normalizedClientKind(from: metadata)
        let intervention = detectIntervention(
            provider: source,
            eventType: eventType,
            sessionKey: sessionKey,
            payload: payload,
            clientKind: clientKind
        )
        let status = detectStatus(
            eventType: eventType,
            payload: payload,
            clientKind: clientKind,
            intervention: intervention
        )
        let expectsResponse = detectExpectsResponse(
            eventType: eventType,
            payload: payload,
            clientKind: clientKind,
            intervention: intervention
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
            expectsResponse: expectsResponse,
            metadata: metadata
        )
    }

    public static func stdoutPayload(
        for provider: AgentProvider,
        response: BridgeResponse,
        eventType: String,
        metadata: [String: String]
    ) -> String {
        guard let decision = response.decision else {
            return "{}"
        }

        switch provider {
        case .claude:
            let clientKind = normalizedClientKind(from: metadata)
            if clientKind == "codebuddy" {
                return codeBuddyStdoutPayload(response: response, decision: decision)
            }
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
                if clientKind == "qoderwork" {
                    return qoderWorkAnswerPayload(
                        response: response,
                        eventType: eventType,
                        answers: answers
                    )
                }
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
        case .copilot:
            // GitHub Copilot uses similar response format to Codex
            switch decision {
            case .approve, .approveForSession:
                return #"{"decision":"accept"}"#
            case .deny:
                return #"{"decision":"decline"}"#
            case .cancel:
                return #"{"decision":"cancel"}"#
            case .answer(let answers):
                return String(data: (try? JSONSerialization.data(withJSONObject: ["answers": answers], options: [.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            }
        }
    }

    private static let codeBuddyApprovalTools: Set<String> = [
        "bash",
        "edit",
        "multiedit",
        "write",
        "task",
        "todowrite"
    ]

    private static let codeBuddyReadOnlyTools: Set<String> = [
        "read",
        "glob",
        "grep",
        "ls",
        "webfetch",
        "websearch"
    ]

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

    private static func detectStatus(
        eventType: String,
        payload: [String: Any],
        clientKind: String?,
        intervention: InterventionRequest?
    ) -> SessionStatus? {
        if let text = payload["status"] as? String {
            return mapStatusString(text)
        }
        if let intervention {
            switch intervention.kind {
            case .approval:
                return SessionStatus(kind: .waitingForApproval)
            case .question:
                return SessionStatus(kind: .waitingForInput)
            }
        }
        if isQoderQuestionToolEvent(eventType: eventType, payload: payload) {
            return SessionStatus(kind: .waitingForInput)
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

    private static func detectExpectsResponse(
        eventType: String,
        payload: [String: Any],
        clientKind: String?,
        intervention: InterventionRequest?
    ) -> Bool {
        if intervention != nil {
            return true
        }

        if clientKind == "qoderwork",
           isQoderWorkPreToolQuestionEvent(eventType: eventType, payload: payload) {
            return true
        }

        if clientKind == "qoderwork",
           isQoderWorkPermissionQuestionEvent(eventType: eventType, payload: payload) {
            return true
        }

        return false
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
        ].compactMap { sanitizedDisplayText($0) }.first
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
        payload: [String: Any],
        clientKind: String?
    ) -> InterventionRequest? {
        if clientKind == "qoderwork",
           eventType == "PostToolUse",
           questionToolNames.contains(normalizedToolName(from: payload) ?? ""),
           payload["tool_response"] != nil {
            return nil
        }

        if let questions = questionPayloads(from: payload), !questions.isEmpty {
            if clientKind == "qoder",
               isQoderQuestionToolEvent(eventType: eventType, payload: payload) {
                return nil
            }
            let options = questions.flatMap { question -> [InterventionOption] in
                let baseID = (question["id"] as? String) ?? UUID().uuidString
                let objectEntries = question["options"] as? [[String: Any]] ?? []
                if !objectEntries.isEmpty {
                    return objectEntries.enumerated().map { index, option in
                        InterventionOption(
                            id: "\(baseID):\(index)",
                            title: option["label"] as? String ?? "Option \(index + 1)",
                            detail: option["description"] as? String
                        )
                    }
                }

                let stringEntries = question["options"] as? [String] ?? []
                if !stringEntries.isEmpty {
                    return stringEntries.enumerated().map { index, option in
                        InterventionOption(
                            id: "\(baseID):\(index)",
                            title: option,
                            detail: nil
                        )
                    }
                }

                if let prompt = (question["question"] as? String) ?? (question["title"] as? String) {
                    return [InterventionOption(id: baseID, title: prompt)]
                }
                return [InterventionOption(id: baseID, title: "Answer")]
            }
            return InterventionRequest(
                sessionID: sessionKey,
                kind: .question,
                title: provider == .claude ? "Claude needs input" : "Codex needs input",
                message: (questions.first?["question"] as? String)
                    ?? (questions.first?["title"] as? String)
                    ?? "Answer required",
                options: options,
                rawContext: flattenMetadata(payload: payload)
            )
        }

        if shouldRequestCodeBuddyApproval(
            eventType: eventType,
            payload: payload,
            clientKind: clientKind
        ) {
            let toolName = (payload["tool_name"] as? String) ?? "Tool"
            let message = summarizeValue(payload["tool_input"])
                .map { "\(toolName) \($0)" }
                ?? toolName
            return InterventionRequest(
                sessionID: sessionKey,
                kind: .approval,
                title: "CodeBuddy needs approval",
                message: message,
                options: [
                    InterventionOption(id: "approve", title: "Allow Once"),
                    InterventionOption(id: "deny", title: "Deny")
                ],
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
        if let toolInput = payload["tool_input"] as? [String: Any],
           JSONSerialization.isValidJSONObject(toolInput),
           let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            metadata["tool_input_json"] = json
        }
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
            return sanitizedDisplayText(string)
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

    private static func normalizedClientKind(from metadata: [String: String]) -> String? {
        metadata["client_kind"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func questionPayloads(from payload: [String: Any]) -> [[String: Any]]? {
        if let questions = payload["questions"] as? [[String: Any]], !questions.isEmpty {
            return questions
        }
        if let questions = decodedQuestions(from: payload["questions"]) {
            return questions
        }
        if let toolInput = payload["tool_input"] as? [String: Any],
           let questions = toolInput["questions"] as? [[String: Any]],
           !questions.isEmpty {
            return questions
        }
        if let toolInput = payload["tool_input"] as? [String: Any],
           let questions = decodedQuestions(from: toolInput["questions"]) {
            return questions
        }
        return nil
    }

    private static func normalizedToolName(from payload: [String: Any]) -> String? {
        guard let toolName = payload["tool_name"] as? String else { return nil }
        return toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func isQoderQuestionToolEvent(eventType: String, payload: [String: Any]) -> Bool {
        guard eventType == "PreToolUse",
              questionToolNames.contains(normalizedToolName(from: payload) ?? ""),
              questionPayloads(from: payload) != nil else {
            return false
        }
        return true
    }

    private static func isQoderWorkPreToolQuestionEvent(eventType: String, payload: [String: Any]) -> Bool {
        guard eventType == "PreToolUse",
              questionToolNames.contains(normalizedToolName(from: payload) ?? ""),
              questionPayloads(from: payload) != nil else {
            return false
        }
        return true
    }

    private static func isQoderWorkPermissionQuestionEvent(eventType: String, payload: [String: Any]) -> Bool {
        guard eventType == "PermissionRequest",
              questionToolNames.contains(normalizedToolName(from: payload) ?? ""),
              questionPayloads(from: payload) != nil else {
            return false
        }
        return true
    }

    private static func normalizedPermissionMode(from payload: [String: Any]) -> String? {
        (payload["permission_mode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }

    private static func shouldRequestCodeBuddyApproval(
        eventType: String,
        payload: [String: Any],
        clientKind: String?
    ) -> Bool {
        guard clientKind == "codebuddy", eventType == "PreToolUse" else {
            return false
        }

        guard let normalizedToolName = normalizedToolName(from: payload) else {
            return false
        }

        if questionToolNames.contains(normalizedToolName), questionPayloads(from: payload) != nil {
            return false
        }

        if let permissionMode = normalizedPermissionMode(from: payload),
           permissionMode == "bypasspermissions" || permissionMode == "plan" {
            return false
        }

        if codeBuddyReadOnlyTools.contains(normalizedToolName) {
            return false
        }

        if codeBuddyApprovalTools.contains(normalizedToolName) {
            return true
        }

        return payload["tool_input"] != nil
    }

    private static func decodedQuestions(from rawValue: Any?) -> [[String: Any]]? {
        guard let rawValue else { return nil }

        if let questions = rawValue as? [[String: Any]], !questions.isEmpty {
            return questions
        }

        if let question = rawValue as? [String: Any] {
            return [question]
        }

        if let string = rawValue as? String,
           let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let questions = json as? [[String: Any]], !questions.isEmpty {
                return questions
            }
            if let question = json as? [String: Any] {
                return [question]
            }
        }

        return nil
    }

    private static func codeBuddyStdoutPayload(
        response: BridgeResponse,
        decision: InterventionDecision
    ) -> String {
        var payload: [String: Any] = [:]

        switch decision {
        case .approve, .approveForSession:
            payload["permissionDecision"] = "allow"
        case .deny, .cancel:
            payload["permissionDecision"] = "deny"
            payload["permissionDecisionReason"] = response.reason ?? "Denied from Island"
        case .answer:
            payload["permissionDecision"] = "allow"
            if let updatedInput = response.updatedInput {
                payload["modifiedInput"] = updatedInput.mapValues(\.foundationObject)
            }
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    private static func qoderWorkAnswerPayload(
        response: BridgeResponse,
        eventType: String,
        answers: [String: String]
    ) -> String {
        let updatedInput = response.updatedInput?.mapValues(\.foundationObject)
            ?? ["answers": answers]
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": eventType,
                "permissionDecision": "allow",
                "updatedInput": updatedInput
            ]
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    private static func sanitizedDisplayText(_ text: String?) -> String? {
        guard let text else { return nil }

        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<system-reminder>.*?</system-reminder>"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<system-reminder>.*$"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }
}
