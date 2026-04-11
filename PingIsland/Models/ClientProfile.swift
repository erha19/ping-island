import Foundation

enum HookProtocolFamily: String, Sendable {
    case claudeHooks
    case codexHooks
    case codexAppServer
}

enum SessionClientBrand: String, Codable, Equatable, Sendable {
    case claude
    case codebuddy
    case codex
    case gemini
    case opencode
    case qoder
    case copilot
    case neutral
}

enum SessionAssistantLabelMode: String, Sendable {
    case providerDisplayName
    case badgeLabel
}

enum HookInstallEntryTemplate: Sendable {
    case plain
    case matcher(String)
}

enum ManagedHookInstallationKind: Sendable, Equatable {
    case jsonHooks
    case pluginFile
}

struct HookInstallEventDescriptor: Sendable {
    let name: String
    let templates: [HookInstallEntryTemplate]
    let timeout: Int?

    init(name: String, templates: [HookInstallEntryTemplate], timeout: Int? = nil) {
        self.name = name
        self.templates = templates
        self.timeout = timeout
    }
}

struct ManagedHookClientProfile: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let installationKind: ManagedHookInstallationKind
    let alwaysVisibleInSettings: Bool
    let logoAssetName: String?
    let prefersBundledLogoOverAppIcon: Bool
    let localAppBundleIdentifiers: [String]
    let iconSymbolName: String
    let configurationRelativePaths: [String]
    let bridgeSource: String
    let bridgeExtraArguments: [String]
    let defaultEnabled: Bool
    let brand: SessionClientBrand
    let events: [HookInstallEventDescriptor]

    init(
        id: String,
        title: String,
        subtitle: String,
        installationKind: ManagedHookInstallationKind = .jsonHooks,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        prefersBundledLogoOverAppIcon: Bool = false,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        configurationRelativePath: String,
        bridgeSource: String,
        bridgeExtraArguments: [String],
        defaultEnabled: Bool,
        brand: SessionClientBrand,
        events: [HookInstallEventDescriptor]
    ) {
        self.init(
            id: id,
            title: title,
            subtitle: subtitle,
            installationKind: installationKind,
            alwaysVisibleInSettings: alwaysVisibleInSettings,
            logoAssetName: logoAssetName,
            prefersBundledLogoOverAppIcon: prefersBundledLogoOverAppIcon,
            localAppBundleIdentifiers: localAppBundleIdentifiers,
            iconSymbolName: iconSymbolName,
            configurationRelativePaths: [configurationRelativePath],
            bridgeSource: bridgeSource,
            bridgeExtraArguments: bridgeExtraArguments,
            defaultEnabled: defaultEnabled,
            brand: brand,
            events: events
        )
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        installationKind: ManagedHookInstallationKind = .jsonHooks,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        prefersBundledLogoOverAppIcon: Bool = false,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        configurationRelativePaths: [String],
        bridgeSource: String,
        bridgeExtraArguments: [String],
        defaultEnabled: Bool,
        brand: SessionClientBrand,
        events: [HookInstallEventDescriptor]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.installationKind = installationKind
        self.alwaysVisibleInSettings = alwaysVisibleInSettings
        self.logoAssetName = logoAssetName
        self.prefersBundledLogoOverAppIcon = prefersBundledLogoOverAppIcon
        self.localAppBundleIdentifiers = localAppBundleIdentifiers
        self.iconSymbolName = iconSymbolName
        self.configurationRelativePaths = configurationRelativePaths
        self.bridgeSource = bridgeSource
        self.bridgeExtraArguments = bridgeExtraArguments
        self.defaultEnabled = defaultEnabled
        self.brand = brand
        self.events = events
    }

    nonisolated var configurationURLs: [URL] {
        configurationRelativePaths.map(Self.resolveConfigurationURL(relativePath:))
    }

    nonisolated var primaryConfigurationURL: URL {
        configurationURLs[0]
    }

    nonisolated var reinstallDescriptionFormat: String {
        switch installationKind {
        case .jsonHooks:
            return "这会重新写入 %@ 的 Island hooks 配置，并保留其他非 Island hooks。"
        case .pluginFile:
            return "这会重新生成 %@ 的 Island 插件文件，并覆盖旧的 Island 托管版本。"
        }
    }

    nonisolated private static func resolveConfigurationURL(relativePath: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return relativePath
            .split(separator: "/")
            .reduce(home) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}

struct SessionClientProfile: Identifiable, Sendable {
    let id: String
    let provider: SessionProvider
    let family: HookProtocolFamily
    let kind: SessionClientKind
    let displayName: String
    let assistantLabelMode: SessionAssistantLabelMode
    let brand: SessionClientBrand
    let defaultBundleIdentifier: String?
    let defaultOrigin: String?
    let recognizedKinds: Set<String>
    let exactAliases: Set<String>
    let keywordAliases: Set<String>
    let bundleIdentifiers: Set<String>

    nonisolated func matchScore(
        explicitKind: String?,
        explicitName: String?,
        explicitBundleIdentifier: String?,
        terminalBundleIdentifier: String?,
        origin: String?,
        originator: String?,
        threadSource: String?,
        processName: String?
    ) -> Int {
        var score = 0

        if let normalizedKind = Self.normalize(explicitKind), recognizedKinds.contains(normalizedKind) {
            score += 100
        }

        let bundleCandidates = [explicitBundleIdentifier, terminalBundleIdentifier]
            .compactMap(Self.normalize)
        if bundleCandidates.contains(where: bundleIdentifiers.contains) {
            score += 90
        }

        let exactCandidates = [explicitName, originator, processName, origin, threadSource]
            .compactMap(Self.normalize)
        if exactCandidates.contains(where: exactAliases.contains) {
            score += 60
        }

        if exactCandidates.contains(where: containsKeywordAlias(_:)) {
            score += 20
        }

        return score
    }

    nonisolated func matchesLabelAlias(_ rawValue: String) -> Bool {
        guard let normalized = Self.normalize(rawValue) else {
            return false
        }
        return exactAliases.contains(normalized)
            || recognizedKinds.contains(normalized)
            || containsKeywordAlias(normalized)
    }

    nonisolated func labelAliasScore(_ rawValue: String) -> Int {
        guard let normalized = Self.normalize(rawValue) else {
            return 0
        }
        if exactAliases.contains(normalized) || recognizedKinds.contains(normalized) {
            return 2
        }
        if containsKeywordAlias(normalized) {
            return 1
        }
        return 0
    }

    nonisolated private func containsKeywordAlias(_ normalizedValue: String) -> Bool {
        keywordAliases.contains { normalizedValue.contains($0) }
    }

    nonisolated private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct ManagedIDEExtensionProfile: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let showsInSettings: Bool
    let alwaysVisibleInSettings: Bool
    let logoAssetName: String?
    let prefersBundledLogoOverAppIcon: Bool
    let sessionFocusStrategy: IDESessionFocusStrategy?
    let localAppBundleIdentifiers: [String]
    let iconSymbolName: String
    let extensionRootRelativePaths: [String]
    let extensionRegistryRelativePaths: [String]
    let uriScheme: String
    let exactBundleIdentifiers: Set<String>
    let bundleIdentifierKeywords: Set<String>
    let appNameKeywords: Set<String>

    init(
        id: String,
        title: String,
        subtitle: String,
        showsInSettings: Bool = true,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        prefersBundledLogoOverAppIcon: Bool = false,
        sessionFocusStrategy: IDESessionFocusStrategy? = nil,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        extensionRootRelativePath: String,
        extensionRegistryRelativePath: String? = nil,
        uriScheme: String,
        exactBundleIdentifiers: Set<String> = [],
        bundleIdentifierKeywords: Set<String> = [],
        appNameKeywords: Set<String> = []
    ) {
        self.init(
            id: id,
            title: title,
            subtitle: subtitle,
            showsInSettings: showsInSettings,
            alwaysVisibleInSettings: alwaysVisibleInSettings,
            logoAssetName: logoAssetName,
            prefersBundledLogoOverAppIcon: prefersBundledLogoOverAppIcon,
            sessionFocusStrategy: sessionFocusStrategy,
            localAppBundleIdentifiers: localAppBundleIdentifiers,
            iconSymbolName: iconSymbolName,
            extensionRootRelativePaths: [extensionRootRelativePath],
            extensionRegistryRelativePaths: extensionRegistryRelativePath.map { [$0] } ?? [],
            uriScheme: uriScheme,
            exactBundleIdentifiers: exactBundleIdentifiers,
            bundleIdentifierKeywords: bundleIdentifierKeywords,
            appNameKeywords: appNameKeywords
        )
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        showsInSettings: Bool = true,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        prefersBundledLogoOverAppIcon: Bool = false,
        sessionFocusStrategy: IDESessionFocusStrategy? = nil,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        extensionRootRelativePaths: [String],
        extensionRegistryRelativePaths: [String] = [],
        uriScheme: String,
        exactBundleIdentifiers: Set<String> = [],
        bundleIdentifierKeywords: Set<String> = [],
        appNameKeywords: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.showsInSettings = showsInSettings
        self.alwaysVisibleInSettings = alwaysVisibleInSettings
        self.logoAssetName = logoAssetName
        self.prefersBundledLogoOverAppIcon = prefersBundledLogoOverAppIcon
        self.sessionFocusStrategy = sessionFocusStrategy
        self.localAppBundleIdentifiers = localAppBundleIdentifiers
        self.iconSymbolName = iconSymbolName
        self.extensionRootRelativePaths = extensionRootRelativePaths
        self.extensionRegistryRelativePaths = extensionRegistryRelativePaths
        self.uriScheme = uriScheme
        self.exactBundleIdentifiers = Set(exactBundleIdentifiers.map { $0.lowercased() })
        self.bundleIdentifierKeywords = Set(bundleIdentifierKeywords.map { $0.lowercased() })
        self.appNameKeywords = Set(appNameKeywords.map { $0.lowercased() })
    }

    nonisolated var supportsSessionFocus: Bool {
        sessionFocusStrategy != nil
    }

    nonisolated var prefersWorkspaceWindowRouting: Bool {
        switch uriScheme {
        case "vscode", "cursor", "trae", "codebuddy", "qoder", "qoder-work":
            return true
        default:
            return false
        }
    }

    nonisolated var prefersWorkspaceURLRouting: Bool {
        uriScheme == "qoder" || uriScheme == "qoder-work"
    }

    nonisolated var extensionRootURLs: [URL] {
        extensionRootRelativePaths.map(Self.resolveRootURL(relativePath:))
    }

    nonisolated var primaryExtensionRootURL: URL {
        extensionRootURLs[0]
    }

    nonisolated var extensionRegistryURLs: [URL] {
        extensionRegistryRelativePaths.map(Self.resolveRootURL(relativePath:))
    }

    nonisolated private static func resolveRootURL(relativePath: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return relativePath
            .split(separator: "/")
            .reduce(home) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}

enum IDESessionFocusStrategy: String, Sendable {
    case qoderChatHistory
}

enum ClientProfileRegistry {
    nonisolated static let managedHookProfiles: [ManagedHookClientProfile] = [
        ManagedHookClientProfile(
            id: "claude-hooks",
            title: "Claude Code",
            subtitle: "管理 ~/.claude/settings.json，使用统一 PingIslandBridge hooks 入口",
            alwaysVisibleInSettings: true,
            logoAssetName: "ClaudeLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.anthropic.claudefordesktop"],
            iconSymbolName: "moon.stars.fill",
            configurationRelativePath: ".claude/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [],
            defaultEnabled: true,
            brand: .claude,
            events: [
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PermissionRequest", templates: [.matcher("*")], timeout: 86_400),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
                HookInstallEventDescriptor(name: "SubagentStop", templates: [.plain]),
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "SessionEnd", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreCompact", templates: [.matcher("auto"), .matcher("manual")]),
            ]
        ),
        ManagedHookClientProfile(
            id: "codex-hooks",
            title: "Codex",
            subtitle: "管理 ~/.codex/hooks.json",
            alwaysVisibleInSettings: true,
            logoAssetName: "CodexLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.openai.codex"],
            iconSymbolName: "apple.terminal.fill",
            configurationRelativePath: ".codex/hooks.json",
            bridgeSource: "codex",
            bridgeExtraArguments: [],
            defaultEnabled: true,
            brand: .codex,
            events: [
                HookInstallEventDescriptor(name: "SessionStart", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PermissionRequest", templates: [.matcher("*")], timeout: 86_400),
                HookInstallEventDescriptor(name: "Stop", templates: [.matcher("*")]),
            ]
        ),
        ManagedHookClientProfile(
            id: "gemini-hooks",
            title: "Gemini CLI",
            subtitle: "管理 ~/.gemini/settings.json，按 Gemini CLI 官方 hooks 协议接入 Island",
            alwaysVisibleInSettings: true,
            logoAssetName: "GeminiLogo",
            prefersBundledLogoOverAppIcon: true,
            iconSymbolName: "sparkles.rectangle.stack.fill",
            configurationRelativePath: ".gemini/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [
                "--client-kind", "gemini",
                "--client-name", "Gemini CLI",
                "--client-origin", "cli",
                "--client-originator", "Gemini CLI",
                "--thread-source", "gemini-hooks"
            ],
            defaultEnabled: false,
            brand: .gemini,
            events: [
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "SessionEnd", templates: [.plain]),
                HookInstallEventDescriptor(name: "BeforeAgent", templates: [.plain]),
                HookInstallEventDescriptor(name: "AfterAgent", templates: [.plain]),
                HookInstallEventDescriptor(name: "BeforeTool", templates: [.matcher(".*")]),
                HookInstallEventDescriptor(name: "AfterTool", templates: [.matcher(".*")]),
                HookInstallEventDescriptor(name: "Notification", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreCompress", templates: [.plain]),
            ]
        ),
        ManagedHookClientProfile(
            id: "codebuddy-hooks",
            title: "CodeBuddy",
            subtitle: "管理 ~/.codebuddy/settings.json，按 CodeBuddy Hooks 协议接入 Island",
            logoAssetName: "CodeBuddyLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.tencent.codebuddy", "com.codebuddy.app"],
            iconSymbolName: "bubble.left.and.bubble.right.fill",
            configurationRelativePath: ".codebuddy/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [
                "--client-kind", "codebuddy",
                "--client-name", "CodeBuddy",
                "--client-originator", "CodeBuddy"
            ],
            defaultEnabled: false,
            brand: .codebuddy,
            events: [
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
                HookInstallEventDescriptor(name: "SubagentStop", templates: [.plain]),
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "SessionEnd", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreCompact", templates: [.matcher("auto"), .matcher("manual")]),
            ]
        ),
        ManagedHookClientProfile(
            id: "cursor-hooks",
            title: "Cursor",
            subtitle: "管理 ~/Library/Application Support/Cursor/User/settings.json，按 Claude Hooks 协议接入 Island",
            logoAssetName: "CursorLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            iconSymbolName: "cursorarrow.rays",
            configurationRelativePath: "Library/Application Support/Cursor/User/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [
                "--client-kind", "cursor",
                "--client-name", "Cursor",
                "--client-originator", "Cursor"
            ],
            defaultEnabled: false,
            brand: .claude,
            events: [
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PermissionRequest", templates: [.matcher("*")], timeout: 86_400),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
                HookInstallEventDescriptor(name: "SubagentStop", templates: [.plain]),
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "SessionEnd", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreCompact", templates: [.matcher("auto"), .matcher("manual")]),
            ]
        ),
        ManagedHookClientProfile(
            id: "qoder-hooks",
            title: "Qoder",
            subtitle: "管理 ~/.qoder/settings.json，支持 Qoder 会话、提问与权限提醒事件",
            logoAssetName: "QoderLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.qoder.ide"],
            iconSymbolName: "bolt.horizontal.circle.fill",
            configurationRelativePath: ".qoder/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: ["--client-kind", "qoder"],
            defaultEnabled: true,
            brand: .qoder,
            events: [
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUseFailure", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PermissionRequest", templates: [.matcher("*")], timeout: 86_400),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
            ]
        ),
        ManagedHookClientProfile(
            id: "qoderwork-hooks",
            title: "QoderWork",
            subtitle: "管理 ~/.qoderwork/settings.json，按 Qoder CLI 同款 Claude Hooks 协议接入 Island",
            logoAssetName: "QoderLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.qoder.work"],
            iconSymbolName: "bolt.horizontal.circle.fill",
            configurationRelativePath: ".qoderwork/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [
                "--client-kind", "qoderwork",
                "--client-name", "QoderWork"
            ],
            defaultEnabled: true,
            brand: .qoder,
            events: [
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")], timeout: 86_400),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUseFailure", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PermissionRequest", templates: [.matcher("*")], timeout: 86_400),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
            ]
        ),
        ManagedHookClientProfile(
            id: "copilot-hooks",
            title: "GitHub Copilot",
            subtitle: "生成 GitHub Copilot hooks JSON，兼容 Copilot CLI / Agent 的 .github/hooks 协议",
            alwaysVisibleInSettings: true,
            logoAssetName: "CopilotLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.github.Copilot", "com.github.CopilotForXcode"],
            iconSymbolName: "chevron.left.forwardslash.chevron.right",
            configurationRelativePath: ".github/hooks/island.json",
            bridgeSource: "copilot",
            bridgeExtraArguments: [],
            defaultEnabled: false,
            brand: .copilot,
            events: [
                HookInstallEventDescriptor(name: "sessionStart", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "sessionEnd", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "userPromptSubmitted", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "preToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "postToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "agentStop", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "subagentStop", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "errorOccurred", templates: [.matcher("*")]),
            ]
        ),
        ManagedHookClientProfile(
            id: "opencode-hooks",
            title: "OpenCode",
            subtitle: "管理 ~/.config/opencode/plugins/ping-island.js，按 OpenCode 官方插件 hooks 接入 Island",
            installationKind: .pluginFile,
            alwaysVisibleInSettings: true,
            logoAssetName: "OpenCodeLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["ai.opencode.desktop"],
            iconSymbolName: "waveform.path.ecg.text",
            configurationRelativePath: ".config/opencode/plugins/ping-island.js",
            bridgeSource: "claude",
            bridgeExtraArguments: [
                "--client-kind", "opencode",
                "--client-name", "OpenCode",
                "--client-origin", "cli",
                "--client-originator", "OpenCode",
                "--thread-source", "opencode-plugin"
            ],
            defaultEnabled: false,
            brand: .opencode,
            events: []
        ),
    ]

    nonisolated static let runtimeProfiles: [SessionClientProfile] = [
        SessionClientProfile(
            id: "claude-code",
            provider: .claude,
            family: .claudeHooks,
            kind: .claudeCode,
            displayName: "Claude Code",
            assistantLabelMode: .providerDisplayName,
            brand: .claude,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["claude-code", "claude_code", "claude code"],
            exactAliases: ["claude", "claude-code", "claude code"],
            keywordAliases: ["claude"],
            bundleIdentifiers: []
        ),
        SessionClientProfile(
            id: "qoder",
            provider: .claude,
            family: .claudeHooks,
            kind: .qoder,
            displayName: "Qoder",
            assistantLabelMode: .badgeLabel,
            brand: .qoder,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["qoder", "qoder-client", "qoder_client", "qoder client"],
            exactAliases: ["qoder", "qoder-client", "qoder client"],
            keywordAliases: ["qoder"],
            bundleIdentifiers: ["com.qoder.ide"]
        ),
        SessionClientProfile(
            id: "qoderwork",
            provider: .claude,
            family: .claudeHooks,
            kind: .qoder,
            displayName: "QoderWork",
            assistantLabelMode: .badgeLabel,
            brand: .qoder,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["qoderwork", "qoder-work", "qoder_work", "qoder work"],
            exactAliases: ["qoderwork", "qoder-work", "qoder work"],
            keywordAliases: ["qoderwork", "qoder work"],
            bundleIdentifiers: ["com.qoder.work"]
        ),
        SessionClientProfile(
            id: "qoder-cli",
            provider: .claude,
            family: .claudeHooks,
            kind: .qoder,
            displayName: "Qoder CLI",
            assistantLabelMode: .badgeLabel,
            brand: .qoder,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["qoder-cli", "qoder_cli", "qoder cli"],
            exactAliases: ["qoder-cli", "qoder cli"],
            keywordAliases: ["qoder cli"],
            bundleIdentifiers: []
        ),
        SessionClientProfile(
            id: "codebuddy",
            provider: .claude,
            family: .claudeHooks,
            kind: .claudeCode,
            displayName: "CodeBuddy",
            assistantLabelMode: .badgeLabel,
            brand: .codebuddy,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["codebuddy", "code-buddy", "codebuddy-client", "codebuddy client"],
            exactAliases: ["codebuddy", "code-buddy", "codebuddy-client", "codebuddy client"],
            keywordAliases: ["codebuddy", "code buddy"],
            bundleIdentifiers: ["com.tencent.codebuddy", "com.codebuddy.app"]
        ),
        SessionClientProfile(
            id: "workbuddy",
            provider: .claude,
            family: .claudeHooks,
            kind: .claudeCode,
            displayName: "WorkBuddy",
            assistantLabelMode: .badgeLabel,
            brand: .codebuddy,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["workbuddy", "work-buddy", "workbuddy-client", "workbuddy client"],
            exactAliases: ["workbuddy", "work-buddy", "workbuddy-client", "workbuddy client"],
            keywordAliases: ["workbuddy", "work buddy"],
            bundleIdentifiers: ["com.workbuddy.workbuddy"]
        ),
        SessionClientProfile(
            id: "trae",
            provider: .claude,
            family: .claudeHooks,
            kind: .claudeCode,
            displayName: "Trae",
            assistantLabelMode: .badgeLabel,
            brand: .claude,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["trae", "trae-ide", "trae ide", "trae-ai", "trae ai"],
            exactAliases: ["trae", "trae-ide", "trae ide", "trae-ai", "trae ai"],
            keywordAliases: ["trae"],
            bundleIdentifiers: []
        ),
        SessionClientProfile(
            id: "cursor",
            provider: .claude,
            family: .claudeHooks,
            kind: .claudeCode,
            displayName: "Cursor",
            assistantLabelMode: .badgeLabel,
            brand: .claude,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["cursor", "cursor-ide", "cursor ide", "cursor-client", "cursor client"],
            exactAliases: ["cursor", "cursor-ide", "cursor ide", "cursor-client", "cursor client"],
            keywordAliases: ["cursor"],
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"]
        ),
        SessionClientProfile(
            id: "jb-plugin",
            provider: .claude,
            family: .claudeHooks,
            kind: .qoder,
            displayName: "Qoder",
            assistantLabelMode: .badgeLabel,
            brand: .qoder,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["jetbrains", "jetbrains-plugin", "jb", "jb-plugin", "jb plugin"],
            exactAliases: ["jetbrains", "jetbrains-plugin", "jetbrains plugin", "jb", "jb-plugin", "jb plugin"],
            keywordAliases: ["jetbrains", "jb plugin"],
            bundleIdentifiers: []
        ),
        SessionClientProfile(
            id: "opencode",
            provider: .claude,
            family: .claudeHooks,
            kind: .custom,
            displayName: "OpenCode",
            assistantLabelMode: .badgeLabel,
            brand: .opencode,
            defaultBundleIdentifier: "ai.opencode.desktop",
            defaultOrigin: "cli",
            recognizedKinds: ["opencode", "open-code", "open_code", "open code"],
            exactAliases: ["opencode", "open-code", "open code"],
            keywordAliases: ["opencode", "open code"],
            bundleIdentifiers: ["ai.opencode.desktop"]
        ),
        SessionClientProfile(
            id: "gemini",
            provider: .claude,
            family: .claudeHooks,
            kind: .custom,
            displayName: "Gemini CLI",
            assistantLabelMode: .badgeLabel,
            brand: .gemini,
            defaultBundleIdentifier: nil,
            defaultOrigin: "cli",
            recognizedKinds: ["gemini", "gemini-cli", "gemini_cli", "gemini cli"],
            exactAliases: ["gemini", "gemini-cli", "gemini cli"],
            keywordAliases: ["gemini", "gemini cli"],
            bundleIdentifiers: []
        ),
        SessionClientProfile(
            id: "codex-app",
            provider: .codex,
            family: .codexHooks,
            kind: .codexApp,
            displayName: "Codex App",
            assistantLabelMode: .providerDisplayName,
            brand: .codex,
            defaultBundleIdentifier: "com.openai.codex",
            defaultOrigin: "desktop",
            recognizedKinds: ["codex-app", "codex_app", "codex app", "app", "desktop"],
            exactAliases: ["codex-app", "codex app", "codex desktop", "desktop"],
            keywordAliases: ["codex app", "codex desktop"],
            bundleIdentifiers: ["com.openai.codex"]
        ),
        SessionClientProfile(
            id: "codex-cli",
            provider: .codex,
            family: .codexHooks,
            kind: .codexCLI,
            displayName: "Codex",
            assistantLabelMode: .providerDisplayName,
            brand: .codex,
            defaultBundleIdentifier: nil,
            defaultOrigin: "cli",
            recognizedKinds: ["codex-cli", "codex_cli", "codex cli", "codex-tui", "codex_tui", "codex tui", "cli", "tui"],
            exactAliases: ["codex", "codex-cli", "codex cli", "codex-tui", "codex tui", "cli", "tui"],
            keywordAliases: ["codex cli", "codex tui"],
            bundleIdentifiers: []
        ),
        SessionClientProfile(
            id: "copilot-cli",
            provider: .copilot,
            family: .codexHooks,
            kind: .custom,
            displayName: "GitHub Copilot",
            assistantLabelMode: .providerDisplayName,
            brand: .copilot,
            defaultBundleIdentifier: nil,
            defaultOrigin: "cli",
            recognizedKinds: ["copilot", "copilot-cli", "copilot cli", "github-copilot", "github copilot"],
            exactAliases: ["copilot", "copilot-cli", "copilot cli", "github copilot"],
            keywordAliases: ["copilot", "github copilot"],
            bundleIdentifiers: ["com.github.copilot", "com.github.copilotforxcode"]
        ),
    ]

    nonisolated static let ideExtensionProfiles: [ManagedIDEExtensionProfile] = [
        ManagedIDEExtensionProfile(
            id: "vscode-extension",
            title: "VS Code",
            subtitle: "安装 Ping Island，支持终端精准聚焦",
            logoAssetName: "VSCodeLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
            iconSymbolName: "square.stack.3d.up.fill",
            extensionRootRelativePath: ".vscode/extensions",
            extensionRegistryRelativePath: ".vscode/extensions/extensions.json",
            uriScheme: "vscode",
            exactBundleIdentifiers: ["com.microsoft.vscode", "com.microsoft.vscode.helper"],
            bundleIdentifierKeywords: ["vscode"],
            appNameKeywords: ["visual studio code", "code helper"]
        ),
        ManagedIDEExtensionProfile(
            id: "cursor-extension",
            title: "Cursor",
            subtitle: "安装 Ping Island，支持终端精准聚焦",
            logoAssetName: "CursorLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            iconSymbolName: "cursorarrow.rays",
            extensionRootRelativePath: ".cursor/extensions",
            extensionRegistryRelativePath: ".cursor/extensions/extensions.json",
            uriScheme: "cursor",
            exactBundleIdentifiers: ["com.todesktop.230313mzl4w4u92", "com.todesktop.230313mzl4w4u92.helper"],
            bundleIdentifierKeywords: ["todesktop", "cursor"],
            appNameKeywords: ["cursor"]
        ),
        ManagedIDEExtensionProfile(
            id: "codebuddy-extension",
            title: "CodeBuddy",
            subtitle: "安装 Ping Island，支持终端精准聚焦",
            logoAssetName: "CodeBuddyLogo",
            prefersBundledLogoOverAppIcon: true,
            localAppBundleIdentifiers: ["com.tencent.codebuddy", "com.codebuddy.app"],
            iconSymbolName: "bubble.left.and.bubble.right.fill",
            extensionRootRelativePaths: [
                ".codebuddy/extensions",
                ".codebuddycn/extensions"
            ],
            extensionRegistryRelativePaths: [
                ".codebuddy/extensions/extensions.json",
                ".codebuddycn/extensions/extensions.json"
            ],
            uriScheme: "codebuddy",
            exactBundleIdentifiers: ["com.tencent.codebuddy", "com.codebuddy.app"],
            bundleIdentifierKeywords: ["codebuddy", "tencent"],
            appNameKeywords: ["codebuddy"]
        ),
        ManagedIDEExtensionProfile(
            id: "workbuddy-extension",
            title: "WorkBuddy",
            subtitle: "安装 Ping Island，支持终端精准聚焦",
            showsInSettings: false,
            localAppBundleIdentifiers: ["com.workbuddy.workbuddy"],
            iconSymbolName: "bubble.left.and.bubble.right.fill",
            extensionRootRelativePath: ".workbuddy/extensions",
            extensionRegistryRelativePath: ".workbuddy/extensions/extensions.json",
            uriScheme: "workbuddy",
            exactBundleIdentifiers: ["com.workbuddy.workbuddy"],
            bundleIdentifierKeywords: ["workbuddy"],
            appNameKeywords: ["workbuddy"]
        ),
        ManagedIDEExtensionProfile(
            id: "qoder-extension",
            title: "Qoder",
            subtitle: "安装 Ping Island，支持会话跳转与终端精准聚焦",
            logoAssetName: "QoderLogo",
            prefersBundledLogoOverAppIcon: true,
            sessionFocusStrategy: .qoderChatHistory,
            localAppBundleIdentifiers: ["com.qoder.ide"],
            iconSymbolName: "bolt.horizontal.circle.fill",
            extensionRootRelativePath: ".qoder/extensions",
            extensionRegistryRelativePath: ".qoder/extensions/extensions.json",
            uriScheme: "qoder",
            exactBundleIdentifiers: ["com.qoder.ide"],
            bundleIdentifierKeywords: ["qoder.ide"],
            appNameKeywords: ["qoder"]
        ),
        ManagedIDEExtensionProfile(
            id: "qoderwork-extension",
            title: "QoderWork",
            subtitle: "安装 Ping Island，支持会话跳转与终端精准聚焦",
            showsInSettings: false,
            logoAssetName: "QoderLogo",
            prefersBundledLogoOverAppIcon: true,
            sessionFocusStrategy: .qoderChatHistory,
            localAppBundleIdentifiers: ["com.qoder.work"],
            iconSymbolName: "bolt.horizontal.circle.fill",
            extensionRootRelativePath: ".qoderwork/extensions",
            uriScheme: "qoder-work",
            exactBundleIdentifiers: ["com.qoder.work"],
            bundleIdentifierKeywords: ["qoder.work"],
            appNameKeywords: ["qoderwork", "qoder work"]
        ),
    ]

    nonisolated static func managedHookProfile(id: String) -> ManagedHookClientProfile? {
        managedHookProfiles.first { $0.id == id }
    }

    nonisolated static func runtimeProfile(id: String?) -> SessionClientProfile? {
        guard let id else { return nil }
        return runtimeProfiles.first { $0.id == id }
    }

    nonisolated static func defaultManagedHookProfileIDs() -> Set<String> {
        Set(managedHookProfiles.filter(\.defaultEnabled).map(\.id))
    }

    nonisolated static func ideExtensionProfile(id: String) -> ManagedIDEExtensionProfile? {
        ideExtensionProfiles.first { $0.id == id }
    }

    nonisolated static func ideExtensionProfile(
        bundleIdentifier: String?,
        appName: String?
    ) -> ManagedIDEExtensionProfile? {
        let normalizedBundle = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedName = appName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let normalizedBundle {
            let exactBundleMatch = ideExtensionProfiles.first { profile in
                profile.exactBundleIdentifiers.contains(normalizedBundle)
            }
            if let exactBundleMatch {
                return exactBundleMatch
            }

            let bundleKeywordMatch = ideExtensionProfiles
                .compactMap { profile -> (ManagedIDEExtensionProfile, Int)? in
                    let longestMatchLength = profile.bundleIdentifierKeywords
                        .filter { normalizedBundle.contains($0) }
                        .map(\.count)
                        .max()
                    guard let longestMatchLength else { return nil }
                    return (profile, longestMatchLength)
                }
                .max { lhs, rhs in
                    lhs.1 < rhs.1
                }
                .map(\.0)
            if let bundleKeywordMatch {
                return bundleKeywordMatch
            }
        }

        guard let normalizedName else { return nil }

        return ideExtensionProfiles
            .compactMap { profile -> (ManagedIDEExtensionProfile, Int)? in
                let longestMatchLength = profile.appNameKeywords
                    .filter { normalizedName.contains($0) }
                    .map(\.count)
                    .max()
                guard let longestMatchLength else { return nil }
                return (profile, longestMatchLength)
            }
            .max { lhs, rhs in
                lhs.1 < rhs.1
            }
            .map(\.0)
    }

    nonisolated static func defaultRuntimeProfile(for provider: SessionProvider, kind: SessionClientKind? = nil) -> SessionClientProfile? {
        switch provider {
        case .claude:
            if kind == .qoder {
                return runtimeProfile(id: "qoder")
            }
            return runtimeProfile(id: "claude-code")
        case .codex:
            return runtimeProfile(id: kind == .codexCLI ? "codex-cli" : "codex-app")
        case .copilot:
            return runtimeProfile(id: "copilot-cli")
        }
    }

    nonisolated static func matchRuntimeProfile(
        provider: SessionProvider,
        explicitKind: String?,
        explicitName: String?,
        explicitBundleIdentifier: String?,
        terminalBundleIdentifier: String?,
        origin: String?,
        originator: String?,
        threadSource: String?,
        processName: String?
    ) -> SessionClientProfile? {
        (
            runtimeProfiles
            .filter { $0.provider == provider }
            .map { profile in
                (
                    profile: profile,
                    score: profile.matchScore(
                        explicitKind: explicitKind,
                        explicitName: explicitName,
                        explicitBundleIdentifier: explicitBundleIdentifier,
                        terminalBundleIdentifier: terminalBundleIdentifier,
                        origin: origin,
                        originator: originator,
                        threadSource: threadSource,
                        processName: processName
                    )
                )
            }
            .filter { $0.score > 0 }
            .max { lhs, rhs in lhs.score < rhs.score }
        )?.profile
    }

    nonisolated static func canonicalDisplayName(
        for rawValue: String,
        provider: SessionProvider,
        kind: SessionClientKind
    ) -> String? {
        let profiles = runtimeProfiles.filter { $0.provider == provider || $0.kind == kind }
        return profiles
            .map { profile in
                (profile: profile, score: profile.labelAliasScore(rawValue))
            }
            .filter { $0.score > 0 }
            .max { lhs, rhs in lhs.score < rhs.score }?
            .profile
            .displayName
    }
}
