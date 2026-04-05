import Foundation

enum HookProtocolFamily: String, Sendable {
    case claudeHooks
    case codexHooks
    case codexAppServer
}

enum SessionClientBrand: String, Codable, Equatable, Sendable {
    case claude
    case codex
    case qoder
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
    let alwaysVisibleInSettings: Bool
    let logoAssetName: String?
    let localAppBundleIdentifiers: [String]
    let iconSymbolName: String
    let configurationRelativePaths: [String]
    let bridgeSource: String
    let bridgeExtraArguments: [String]
    let defaultEnabled: Bool
    let installsClaudePythonScript: Bool
    let brand: SessionClientBrand
    let events: [HookInstallEventDescriptor]

    init(
        id: String,
        title: String,
        subtitle: String,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        configurationRelativePath: String,
        bridgeSource: String,
        bridgeExtraArguments: [String],
        defaultEnabled: Bool,
        installsClaudePythonScript: Bool,
        brand: SessionClientBrand,
        events: [HookInstallEventDescriptor]
    ) {
        self.init(
            id: id,
            title: title,
            subtitle: subtitle,
            alwaysVisibleInSettings: alwaysVisibleInSettings,
            logoAssetName: logoAssetName,
            localAppBundleIdentifiers: localAppBundleIdentifiers,
            iconSymbolName: iconSymbolName,
            configurationRelativePaths: [configurationRelativePath],
            bridgeSource: bridgeSource,
            bridgeExtraArguments: bridgeExtraArguments,
            defaultEnabled: defaultEnabled,
            installsClaudePythonScript: installsClaudePythonScript,
            brand: brand,
            events: events
        )
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        configurationRelativePaths: [String],
        bridgeSource: String,
        bridgeExtraArguments: [String],
        defaultEnabled: Bool,
        installsClaudePythonScript: Bool,
        brand: SessionClientBrand,
        events: [HookInstallEventDescriptor]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.alwaysVisibleInSettings = alwaysVisibleInSettings
        self.logoAssetName = logoAssetName
        self.localAppBundleIdentifiers = localAppBundleIdentifiers
        self.iconSymbolName = iconSymbolName
        self.configurationRelativePaths = configurationRelativePaths
        self.bridgeSource = bridgeSource
        self.bridgeExtraArguments = bridgeExtraArguments
        self.defaultEnabled = defaultEnabled
        self.installsClaudePythonScript = installsClaudePythonScript
        self.brand = brand
        self.events = events
    }

    nonisolated var configurationURLs: [URL] {
        configurationRelativePaths.map(Self.resolveConfigurationURL(relativePath:))
    }

    nonisolated var primaryConfigurationURL: URL {
        configurationURLs[0]
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
    let alwaysVisibleInSettings: Bool
    let supportsSessionHistoryFocus: Bool
    let localAppBundleIdentifiers: [String]
    let iconSymbolName: String
    let extensionRootRelativePaths: [String]
    let uriScheme: String
    let exactBundleIdentifiers: Set<String>
    let bundleIdentifierKeywords: Set<String>
    let appNameKeywords: Set<String>

    init(
        id: String,
        title: String,
        subtitle: String,
        alwaysVisibleInSettings: Bool = false,
        supportsSessionHistoryFocus: Bool = false,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        extensionRootRelativePath: String,
        uriScheme: String,
        exactBundleIdentifiers: Set<String> = [],
        bundleIdentifierKeywords: Set<String> = [],
        appNameKeywords: Set<String> = []
    ) {
        self.init(
            id: id,
            title: title,
            subtitle: subtitle,
            alwaysVisibleInSettings: alwaysVisibleInSettings,
            supportsSessionHistoryFocus: supportsSessionHistoryFocus,
            localAppBundleIdentifiers: localAppBundleIdentifiers,
            iconSymbolName: iconSymbolName,
            extensionRootRelativePaths: [extensionRootRelativePath],
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
        alwaysVisibleInSettings: Bool = false,
        supportsSessionHistoryFocus: Bool = false,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        extensionRootRelativePaths: [String],
        uriScheme: String,
        exactBundleIdentifiers: Set<String> = [],
        bundleIdentifierKeywords: Set<String> = [],
        appNameKeywords: Set<String> = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.alwaysVisibleInSettings = alwaysVisibleInSettings
        self.supportsSessionHistoryFocus = supportsSessionHistoryFocus
        self.localAppBundleIdentifiers = localAppBundleIdentifiers
        self.iconSymbolName = iconSymbolName
        self.extensionRootRelativePaths = extensionRootRelativePaths
        self.uriScheme = uriScheme
        self.exactBundleIdentifiers = Set(exactBundleIdentifiers.map { $0.lowercased() })
        self.bundleIdentifierKeywords = Set(bundleIdentifierKeywords.map { $0.lowercased() })
        self.appNameKeywords = Set(appNameKeywords.map { $0.lowercased() })
    }

    nonisolated var extensionRootURLs: [URL] {
        extensionRootRelativePaths.map(Self.resolveRootURL(relativePath:))
    }

    nonisolated var primaryExtensionRootURL: URL {
        extensionRootURLs[0]
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

enum ClientProfileRegistry {
    nonisolated static let managedHookProfiles: [ManagedHookClientProfile] = [
        ManagedHookClientProfile(
            id: "claude-hooks",
            title: "Claude Code",
            subtitle: "管理 ~/.claude/settings.json 与 ~/.claude/hooks/island-state.py",
            alwaysVisibleInSettings: true,
            logoAssetName: "ClaudeLogo",
            localAppBundleIdentifiers: ["com.anthropic.claudefordesktop"],
            iconSymbolName: "moon.stars.fill",
            configurationRelativePath: ".claude/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [],
            defaultEnabled: true,
            installsClaudePythonScript: true,
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
            localAppBundleIdentifiers: ["com.openai.codex"],
            iconSymbolName: "apple.terminal.fill",
            configurationRelativePath: ".codex/hooks.json",
            bridgeSource: "codex",
            bridgeExtraArguments: [],
            defaultEnabled: true,
            installsClaudePythonScript: false,
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
            id: "codebuddy-hooks",
            title: "CodeBuddy",
            subtitle: "管理 ~/.codebuddy/settings.json，按 Claude Hooks 协议接入 Island",
            localAppBundleIdentifiers: ["com.tencent.codebuddy"],
            iconSymbolName: "bubble.left.and.bubble.right.fill",
            configurationRelativePath: ".codebuddy/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [
                "--client-kind", "codebuddy",
                "--client-name", "CodeBuddy",
                "--client-originator", "CodeBuddy"
            ],
            defaultEnabled: false,
            installsClaudePythonScript: false,
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
            id: "trae-hooks",
            title: "Trae",
            subtitle: "管理 ~/Library/Application Support/Trae*/User/settings.json，按 Claude Hooks 协议接入 Island",
            localAppBundleIdentifiers: ["com.trae.app"],
            iconSymbolName: "bolt.circle.fill",
            configurationRelativePaths: [
                "Library/Application Support/Trae/User/settings.json",
                "Library/Application Support/Trae CN/User/settings.json",
                ".trae/settings.json"
            ],
            bridgeSource: "claude",
            bridgeExtraArguments: [
                "--client-kind", "trae",
                "--client-name", "Trae",
                "--client-originator", "Trae"
            ],
            defaultEnabled: false,
            installsClaudePythonScript: false,
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
            id: "cursor-hooks",
            title: "Cursor",
            subtitle: "管理 ~/Library/Application Support/Cursor/User/settings.json，按 Claude Hooks 协议接入 Island",
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
            installsClaudePythonScript: false,
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
            subtitle: "管理 ~/.qoder/settings.json，支持 UserPromptSubmit、PreToolUse、PostToolUse、PostToolUseFailure、Stop",
            logoAssetName: "QoderLogo",
            localAppBundleIdentifiers: ["com.qoder.ide"],
            iconSymbolName: "bolt.horizontal.circle.fill",
            configurationRelativePath: ".qoder/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: ["--client-kind", "qoder"],
            defaultEnabled: true,
            installsClaudePythonScript: false,
            brand: .qoder,
            events: [
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUseFailure", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
            ]
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
            id: "codebuddy",
            provider: .claude,
            family: .claudeHooks,
            kind: .claudeCode,
            displayName: "CodeBuddy",
            assistantLabelMode: .badgeLabel,
            brand: .claude,
            defaultBundleIdentifier: nil,
            defaultOrigin: nil,
            recognizedKinds: ["codebuddy", "code-buddy", "codebuddy-client", "codebuddy client"],
            exactAliases: ["codebuddy", "code-buddy", "codebuddy-client", "codebuddy client"],
            keywordAliases: ["codebuddy", "code buddy"],
            bundleIdentifiers: []
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
    ]

    nonisolated static let ideExtensionProfiles: [ManagedIDEExtensionProfile] = [
        ManagedIDEExtensionProfile(
            id: "vscode-extension",
            title: "VS Code",
            subtitle: "安装 Ping Island，支持精准跳到对应终端",
            localAppBundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
            iconSymbolName: "square.stack.3d.up.fill",
            extensionRootRelativePath: ".vscode/extensions",
            uriScheme: "vscode",
            exactBundleIdentifiers: ["com.microsoft.vscode", "com.microsoft.vscode.helper"],
            bundleIdentifierKeywords: ["vscode"],
            appNameKeywords: ["visual studio code", "code helper"]
        ),
        ManagedIDEExtensionProfile(
            id: "cursor-extension",
            title: "Cursor",
            subtitle: "安装 Ping Island，支持精准跳到对应终端",
            localAppBundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            iconSymbolName: "cursorarrow.rays",
            extensionRootRelativePath: ".cursor/extensions",
            uriScheme: "cursor",
            exactBundleIdentifiers: ["com.todesktop.230313mzl4w4u92", "com.todesktop.230313mzl4w4u92.helper"],
            bundleIdentifierKeywords: ["todesktop", "cursor"],
            appNameKeywords: ["cursor"]
        ),
        ManagedIDEExtensionProfile(
            id: "trae-extension",
            title: "Trae",
            subtitle: "安装 Ping Island，支持精准跳到对应终端",
            localAppBundleIdentifiers: ["com.trae.app"],
            iconSymbolName: "bolt.circle.fill",
            extensionRootRelativePaths: [
                ".trae/extensions",
                ".trae-cn/extensions"
            ],
            uriScheme: "trae",
            bundleIdentifierKeywords: ["trae"],
            appNameKeywords: ["trae"]
        ),
        ManagedIDEExtensionProfile(
            id: "codebuddy-extension",
            title: "CodeBuddy",
            subtitle: "安装 Ping Island，支持精准跳到对应终端",
            localAppBundleIdentifiers: ["com.tencent.codebuddy"],
            iconSymbolName: "bubble.left.and.bubble.right.fill",
            extensionRootRelativePaths: [
                ".codebuddy/extensions",
                ".codebuddycn/extensions"
            ],
            uriScheme: "codebuddy",
            exactBundleIdentifiers: ["com.tencent.codebuddy"],
            bundleIdentifierKeywords: ["codebuddy", "tencent"],
            appNameKeywords: ["codebuddy"]
        ),
        ManagedIDEExtensionProfile(
            id: "qoder-extension",
            title: "Qoder",
            subtitle: "安装 Ping Island，支持会话跳转与终端精准聚焦",
            supportsSessionHistoryFocus: true,
            localAppBundleIdentifiers: ["com.qoder.ide"],
            iconSymbolName: "bolt.horizontal.circle.fill",
            extensionRootRelativePath: ".qoder/extensions",
            uriScheme: "qoder",
            exactBundleIdentifiers: ["com.qoder.ide"],
            bundleIdentifierKeywords: ["qoder"],
            appNameKeywords: ["qoder"]
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

        return ideExtensionProfiles.first { profile in
            if let normalizedBundle {
                if profile.exactBundleIdentifiers.contains(normalizedBundle) {
                    return true
                }

                if profile.bundleIdentifierKeywords.contains(where: { normalizedBundle.contains($0) }) {
                    return true
                }
            }

            if let normalizedName,
               profile.appNameKeywords.contains(where: { normalizedName.contains($0) }) {
                return true
            }

            return false
        }
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
        return profiles.first { $0.matchesLabelAlias(rawValue) }?.displayName
    }
}
