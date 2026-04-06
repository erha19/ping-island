import Foundation

enum SessionProvider: String, Codable, Equatable, Sendable {
    case claude
    case codex

    nonisolated var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }
}

enum SessionIngress: String, Equatable, Sendable {
    case hookBridge
    case codexAppServer
}

enum SessionClientKind: String, Codable, Equatable, Sendable {
    case claudeCode
    case codexCLI
    case codexApp
    case qoder
    case custom
    case unknown
}

struct SessionClientInfo: Codable, Equatable, Sendable {
    var kind: SessionClientKind
    var profileID: String?
    var name: String?
    var bundleIdentifier: String?
    var launchURL: String?
    var origin: String?
    var originator: String?
    var threadSource: String?
    var transport: String?
    var remoteHost: String?
    var sessionFilePath: String?
    var terminalBundleIdentifier: String?
    var terminalProgram: String?
    var terminalSessionIdentifier: String?
    var iTermSessionIdentifier: String?
    var tmuxSessionIdentifier: String?
    var tmuxPaneIdentifier: String?
    var processName: String?

    nonisolated init(
        kind: SessionClientKind,
        profileID: String? = nil,
        name: String? = nil,
        bundleIdentifier: String? = nil,
        launchURL: String? = nil,
        origin: String? = nil,
        originator: String? = nil,
        threadSource: String? = nil,
        transport: String? = nil,
        remoteHost: String? = nil,
        sessionFilePath: String? = nil,
        terminalBundleIdentifier: String? = nil,
        terminalProgram: String? = nil,
        terminalSessionIdentifier: String? = nil,
        iTermSessionIdentifier: String? = nil,
        tmuxSessionIdentifier: String? = nil,
        tmuxPaneIdentifier: String? = nil,
        processName: String? = nil
    ) {
        self.kind = kind
        self.profileID = profileID?.nonEmpty
        self.name = name?.nonEmpty
        self.bundleIdentifier = bundleIdentifier?.nonEmpty
        self.launchURL = launchURL?.nonEmpty
        self.origin = origin?.nonEmpty
        self.originator = originator?.nonEmpty
        self.threadSource = threadSource?.nonEmpty
        self.transport = transport?.nonEmpty
        self.remoteHost = remoteHost?.nonEmpty
        self.sessionFilePath = sessionFilePath?.nonEmpty
        self.terminalBundleIdentifier = terminalBundleIdentifier?.nonEmpty
        self.terminalProgram = terminalProgram?.nonEmpty
        self.terminalSessionIdentifier = terminalSessionIdentifier?.nonEmpty
        self.iTermSessionIdentifier = iTermSessionIdentifier?.nonEmpty
        self.tmuxSessionIdentifier = tmuxSessionIdentifier?.nonEmpty
        self.tmuxPaneIdentifier = tmuxPaneIdentifier?.nonEmpty
        self.processName = processName?.nonEmpty
    }

    nonisolated static func `default`(for provider: SessionProvider) -> SessionClientInfo {
        if let profile = ClientProfileRegistry.defaultRuntimeProfile(for: provider) {
            return SessionClientInfo(
                kind: profile.kind,
                profileID: profile.id,
                name: profile.displayName,
                bundleIdentifier: profile.defaultBundleIdentifier,
                origin: profile.defaultOrigin
            )
        }

        switch provider {
        case .claude:
            return SessionClientInfo(kind: .claudeCode, name: "Claude Code")
        case .codex:
            return SessionClientInfo(kind: .codexApp, name: "Codex App", bundleIdentifier: "com.openai.codex")
        }
    }

    nonisolated static func codexApp(threadId: String) -> SessionClientInfo {
        SessionClientInfo(
            kind: .codexApp,
            profileID: "codex-app",
            name: "Codex App",
            bundleIdentifier: "com.openai.codex",
            launchURL: appLaunchURL(bundleIdentifier: "com.openai.codex", sessionId: threadId),
            origin: "desktop"
        )
    }

    nonisolated static func codexCLI() -> SessionClientInfo {
        SessionClientInfo(
            kind: .codexCLI,
            profileID: "codex-cli",
            name: "Codex CLI",
            origin: "cli"
        )
    }

    nonisolated func resolvedProfile(for provider: SessionProvider) -> SessionClientProfile? {
        ClientProfileRegistry.runtimeProfile(id: profileID)
            ?? ClientProfileRegistry.defaultRuntimeProfile(for: provider, kind: kind)
    }

    nonisolated var brand: SessionClientBrand {
        if let profile = ClientProfileRegistry.runtimeProfile(id: profileID) {
            return profile.brand
        }

        switch kind {
        case .claudeCode:
            return .claude
        case .codexCLI, .codexApp:
            return .codex
        case .qoder:
            return .qoder
        case .custom, .unknown:
            return .neutral
        }
    }

    nonisolated func badgeLabel(for provider: SessionProvider) -> String {
        let profile = resolvedProfile(for: provider)
        if let name {
            return Self.normalizedBadgeLabel(name, provider: provider, kind: kind) ?? name
        }
        if let originator {
            return Self.normalizedBadgeLabel(originator, provider: provider, kind: kind) ?? originator
        }
        return profile?.displayName ?? provider.displayName
    }

    nonisolated func assistantLabel(for provider: SessionProvider) -> String {
        switch resolvedProfile(for: provider)?.assistantLabelMode {
        case .badgeLabel:
            return badgeLabel(for: provider)
        case .providerDisplayName, .none:
            return provider.displayName
        }
    }

    nonisolated var interactionOriginDisplayName: String? {
        guard isHostedInIDE else { return nil }
        let hostBundleIdentifier = (terminalBundleIdentifier ?? bundleIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if hostBundleIdentifier == "com.qoder.work" || profileID == "qoderwork" {
            return "QoderWork"
        }
        return ideHostProfile?.title
    }

    nonisolated func interactionLabel(for provider: SessionProvider) -> String {
        interactionOriginDisplayName ?? badgeLabel(for: provider)
    }

    nonisolated var isQoderFamily: Bool {
        brand == .qoder
    }

    nonisolated var ideHostProfile: ManagedIDEExtensionProfile? {
        let detectedBundleIdentifier = terminalBundleIdentifier ?? bundleIdentifier
        let appName: String?
        if let detectedBundleIdentifier,
           TerminalAppRegistry.isTerminalBundle(detectedBundleIdentifier),
           !TerminalAppRegistry.isIDEBundle(detectedBundleIdentifier) {
            appName = nil
        } else {
            appName = originator ?? name
        }
        return ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: detectedBundleIdentifier,
            appName: appName
        )
    }

    nonisolated var isHostedInIDE: Bool {
        guard let ideHostProfile else { return false }
        if terminalBundleIdentifier != nil {
            return true
        }
        if let threadSource = threadSource?.lowercased(),
           threadSource.contains("ide") {
            return true
        }
        return ideHostProfile.prefersWorkspaceWindowRouting
    }

    nonisolated func ideHostBadgeLabel(for provider: SessionProvider) -> String? {
        if profileID == "qoderwork"
            || (terminalBundleIdentifier ?? bundleIdentifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "com.qoder.work" {
            return nil
        }

        guard isHostedInIDE,
              let ideTitle = ideHostProfile?.title else {
            return nil
        }

        let primaryLabel = badgeLabel(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard primaryLabel != ideTitle.lowercased() else {
            return nil
        }

        return "\(ideTitle) 终端"
    }

    nonisolated var prefersAppNavigation: Bool {
        if kind == .codexCLI {
            return false
        }
        return kind == .codexApp || launchURL != nil || bundleIdentifier == "com.openai.codex"
    }

    nonisolated func normalizedForCodexRouting(sessionId: String? = nil) -> SessionClientInfo {
        var normalized = self

        switch normalized.kind {
        case .codexCLI:
            if normalized.profileID == nil {
                normalized.profileID = "codex-cli"
            }
            if normalized.name == nil || normalized.name == "Codex App" {
                normalized.name = "Codex CLI"
            }

            if normalized.bundleIdentifier == "com.openai.codex" {
                normalized.bundleIdentifier = nil
            }

            if let launchURL = normalized.launchURL?.lowercased(),
               launchURL.hasPrefix("codex://") {
                normalized.launchURL = nil
            }

        case .codexApp:
            if normalized.profileID == nil {
                normalized.profileID = "codex-app"
            }
            if normalized.name == nil {
                normalized.name = "Codex App"
            }

            if normalized.bundleIdentifier == nil {
                normalized.bundleIdentifier = "com.openai.codex"
            }

            if let sessionId,
               Self.isLegacyCodexThreadURL(normalized.launchURL) {
                normalized.launchURL = Self.appLaunchURL(
                    bundleIdentifier: normalized.bundleIdentifier ?? "com.openai.codex",
                    sessionId: sessionId
                )
            } else if normalized.launchURL == nil,
               let sessionId,
               let bundleIdentifier = normalized.bundleIdentifier {
                normalized.launchURL = Self.appLaunchURL(
                    bundleIdentifier: bundleIdentifier,
                    sessionId: sessionId
                )
            }

        case .claudeCode, .qoder, .custom, .unknown:
            break
        }

        return normalized
    }

    nonisolated func normalizedForClaudeRouting() -> SessionClientInfo {
        var normalized = self

        guard normalized.kind == .qoder else {
            return normalized
        }

        let hostBundleIdentifier = (
            normalized.terminalBundleIdentifier
                ?? normalized.bundleIdentifier
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isQoderWorkHosted =
            hostBundleIdentifier == "com.qoder.work"
            || normalized.profileID == "qoderwork"
            || normalized.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "qoderwork"
            || normalized.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "qoder work"
        let isIDEBundle = hostBundleIdentifier.map { TerminalAppRegistry.isIDEBundle($0) } ?? false
        let isTerminalHosted =
            (hostBundleIdentifier.map { TerminalAppRegistry.isTerminalBundle($0) } ?? false)
            && !isIDEBundle
            && !isQoderWorkHosted
        let isQoderIDEHosted =
            hostBundleIdentifier == "com.qoder.ide"
            || (
                normalized.ideHostProfile?.id == "qoder-extension"
                    && !isQoderWorkHosted
            )
            || normalized.profileID == "qoder"
                && (
                    normalized.terminalBundleIdentifier?.lowercased() == "com.qoder.ide"
                        || normalized.bundleIdentifier?.lowercased() == "com.qoder.ide"
                )

        if isTerminalHosted {
            normalized.profileID = "qoder-cli"
            normalized.name = "Qoder CLI"
        } else if isQoderWorkHosted {
            normalized.profileID = "qoderwork"
            normalized.name = "QoderWork"
        } else if isQoderIDEHosted {
            normalized.profileID = "qoder"
            normalized.name = "Qoder"
        } else if normalized.profileID == "qoder-cli"
            || normalized.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "qoder cli"
            || normalized.origin?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cli" {
            normalized.profileID = "qoder-cli"
            normalized.name = "Qoder CLI"
        } else if normalized.profileID == nil, normalized.name == nil {
            normalized.profileID = "qoder"
            normalized.name = "Qoder"
        }

        return normalized
    }

    nonisolated var terminalContextSummary: String? {
        let transportLabel: String?
        if let transport {
            if let remoteHost {
                transportLabel = "\(transport)@\(remoteHost)"
            } else {
                transportLabel = transport
            }
        } else {
            transportLabel = remoteHost
        }

        let parts = [
            originator,
            threadSource,
            transportLabel,
            terminalProgram,
            tmuxPaneIdentifier
        ].compactMap { $0?.nonEmpty }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    nonisolated func merged(with newer: SessionClientInfo) -> SessionClientInfo {
        var merged = self

        if merged.kind == .unknown || newer.kind != .unknown {
            merged.kind = newer.kind
        }
        if let profileID = newer.profileID?.nonEmpty {
            merged.profileID = profileID
        }

        if let name = newer.name?.nonEmpty {
            merged.name = name
        }
        if let bundleIdentifier = newer.bundleIdentifier?.nonEmpty {
            merged.bundleIdentifier = bundleIdentifier
        }
        if let launchURL = newer.launchURL?.nonEmpty {
            merged.launchURL = launchURL
        }
        if let origin = newer.origin?.nonEmpty {
            merged.origin = origin
        }
        if let originator = newer.originator?.nonEmpty {
            merged.originator = originator
        }
        if let threadSource = newer.threadSource?.nonEmpty {
            merged.threadSource = threadSource
        }
        if let transport = newer.transport?.nonEmpty {
            merged.transport = transport
        }
        if let remoteHost = newer.remoteHost?.nonEmpty {
            merged.remoteHost = remoteHost
        }
        if let sessionFilePath = newer.sessionFilePath?.nonEmpty {
            merged.sessionFilePath = sessionFilePath
        }
        if let terminalBundleIdentifier = newer.terminalBundleIdentifier?.nonEmpty {
            merged.terminalBundleIdentifier = terminalBundleIdentifier
        }
        if let terminalProgram = newer.terminalProgram?.nonEmpty {
            merged.terminalProgram = terminalProgram
        }
        if let terminalSessionIdentifier = newer.terminalSessionIdentifier?.nonEmpty {
            merged.terminalSessionIdentifier = terminalSessionIdentifier
        }
        if let iTermSessionIdentifier = newer.iTermSessionIdentifier?.nonEmpty {
            merged.iTermSessionIdentifier = iTermSessionIdentifier
        }
        if let tmuxSessionIdentifier = newer.tmuxSessionIdentifier?.nonEmpty {
            merged.tmuxSessionIdentifier = tmuxSessionIdentifier
        }
        if let tmuxPaneIdentifier = newer.tmuxPaneIdentifier?.nonEmpty {
            merged.tmuxPaneIdentifier = tmuxPaneIdentifier
        }
        if let processName = newer.processName?.nonEmpty {
            merged.processName = processName
        }

        return merged
    }

    private nonisolated static func normalizedBadgeLabel(
        _ rawValue: String,
        provider: SessionProvider,
        kind: SessionClientKind
    ) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let canonical = ClientProfileRegistry.canonicalDisplayName(for: trimmed, provider: provider, kind: kind) {
            return canonical
        }

        let normalized = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if provider == .codex, kind == .codexCLI, normalized.hasPrefix("codex-") {
            return "Codex"
        }
        return nil
    }

    nonisolated static func appLaunchURL(
        bundleIdentifier: String,
        sessionId: String? = nil,
        workspacePath: String? = nil
    ) -> String? {
        let normalizedBundleIdentifier = bundleIdentifier.lowercased()

        switch normalizedBundleIdentifier {
        case "com.openai.codex":
            guard let sessionId else { return nil }
            return codexThreadURL(threadId: sessionId)
        case "com.todesktop.230313mzl4w4u92":
            return workspacePath.flatMap { workspaceURL(scheme: "cursor", path: $0) }
        case "com.microsoft.vscode":
            return workspacePath.flatMap { workspaceURL(scheme: "vscode", path: $0) }
        case "com.microsoft.vscodeinsiders":
            return workspacePath.flatMap { workspaceURL(scheme: "vscode-insiders", path: $0) }
        case "com.qoder.work":
            return workspacePath.flatMap { workspaceURL(scheme: "qoder-work", path: $0) }
        case "com.qoder.ide":
            return workspacePath.flatMap { workspaceURL(scheme: "qoder", path: $0) }
        default:
            if normalizedBundleIdentifier.contains("qoder") {
                return workspacePath.flatMap { workspaceURL(scheme: "qoder", path: $0) }
            }
            if normalizedBundleIdentifier.contains("trae") {
                return workspacePath.flatMap { workspaceURL(scheme: "trae", path: $0) }
            }
            if normalizedBundleIdentifier.contains("codebuddy") {
                return workspacePath.flatMap { workspaceURL(scheme: "codebuddy", path: $0) }
            }
            return nil
        }
    }

    private nonisolated static func codexThreadURL(threadId: String) -> String {
        let encodedThreadId = threadId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? threadId
        return "codex://threads/\(encodedThreadId)"
    }

    private nonisolated static func isLegacyCodexThreadURL(_ url: String?) -> Bool {
        guard let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalizedURL.hasPrefix("codex://local/")
    }

    private nonisolated static func workspaceURL(scheme: String, path: String) -> String? {
        let trimmedPath = path.nonEmpty ?? ""
        guard !trimmedPath.isEmpty else { return nil }
        let encodedPath = trimmedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedPath
        return "\(scheme)://file\(encodedPath)"
    }
}

enum SessionInterventionKind: String, Sendable {
    case approval
    case question
}

struct SessionInterventionOption: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String?

    nonisolated var mergeSignature: String {
        [id, title, detail ?? ""].joined(separator: "|")
    }
}

struct SessionInterventionQuestion: Equatable, Identifiable, Sendable {
    let id: String
    let header: String
    let prompt: String
    let detail: String?
    let options: [SessionInterventionOption]
    let allowsMultiple: Bool
    let allowsOther: Bool
    let isSecret: Bool

    nonisolated var mergeSignature: String {
        let optionSignature = options.map(\.mergeSignature).joined(separator: "||")
        return [
            id,
            header,
            prompt,
            detail ?? "",
            allowsMultiple ? "1" : "0",
            allowsOther ? "1" : "0",
            isSecret ? "1" : "0",
            optionSignature
        ].joined(separator: "|")
    }
}

struct SessionIntervention: Equatable, Identifiable, Sendable {
    private nonisolated static let externalContinuationTimeout: TimeInterval = 5 * 60
    private nonisolated static let submittedAnswersMetadataKey = "submittedAnswersJSON"

    let id: String
    let kind: SessionInterventionKind
    let title: String
    let message: String
    let options: [SessionInterventionOption]
    let questions: [SessionInterventionQuestion]
    let supportsSessionScope: Bool
    let metadata: [String: String]

    nonisolated var supportsInlineResponse: Bool {
        metadata["responseMode"] != "external_only"
    }

    nonisolated var awaitsExternalContinuation: Bool {
        metadata["continuationState"] == "awaiting_client_followup"
    }

    nonisolated var externalContinuationAnsweredAt: Date? {
        guard let rawValue = metadata["continuationAnsweredAt"],
              let timestamp = TimeInterval(rawValue) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    nonisolated var externalContinuationDeadline: Date? {
        guard let answeredAt = externalContinuationAnsweredAt else { return nil }
        return answeredAt.addingTimeInterval(Self.externalContinuationTimeout)
    }

    nonisolated var externalContinuationStatusMessage: String? {
        guard awaitsExternalContinuation else { return nil }
        let actorName = metadata["continuationActorName"] ?? "客户端"
        return "\(actorName) 需要你进行后续操作，可通过上方按钮快速响应"
    }

    nonisolated var submittedAnswers: [String: [String]] {
        guard let rawJSON = metadata[Self.submittedAnswersMetadataKey],
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        return object.reduce(into: [String: [String]]()) { partial, entry in
            switch entry.value {
            case let value as String:
                guard !value.isEmpty else { return }
                partial[entry.key] = [value]
            case let values as [String]:
                let filtered = values.filter { !$0.isEmpty }
                guard !filtered.isEmpty else { return }
                partial[entry.key] = filtered
            default:
                break
            }
        }
    }

    nonisolated func hasTimedOutExternalContinuation(now: Date = Date()) -> Bool {
        guard let deadline = externalContinuationDeadline else { return false }
        return now >= deadline
    }

    nonisolated func markingAwaitingExternalContinuation(
        actorName: String,
        answeredAt: Date = Date(),
        selectedAnswers: [String: [String]]? = nil
    ) -> SessionIntervention {
        var updatedMetadata = metadata
        updatedMetadata["continuationState"] = "awaiting_client_followup"
        updatedMetadata["continuationAnsweredAt"] = String(answeredAt.timeIntervalSince1970)
        updatedMetadata["continuationActorName"] = actorName
        if let selectedAnswers = selectedAnswers,
           let data = try? JSONSerialization.data(withJSONObject: selectedAnswers, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            updatedMetadata[Self.submittedAnswersMetadataKey] = json
        }

        return SessionIntervention(
            id: id,
            kind: kind,
            title: title,
            message: message,
            options: options,
            questions: questions,
            supportsSessionScope: supportsSessionScope,
            metadata: updatedMetadata
        )
    }

    nonisolated var summaryText: String {
        if kind == .question, let firstQuestion = questions.first {
            return firstQuestion.prompt
        }
        if !message.isEmpty {
            return message
        }
        if let firstQuestion = questions.first {
            return firstQuestion.prompt
        }
        if let firstOption = options.first {
            return firstOption.title
        }
        return title
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
