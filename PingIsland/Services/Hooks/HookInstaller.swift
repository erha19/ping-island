//
//  HookInstaller.swift
//  PingIsland
//
//  Installs and manages hook integrations for supported clients.
//

import Foundation

private enum HookConfigParser {
    static func parseJSONObject(from data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let sanitized = removeTrailingCommas(from: stripJSONComments(from: string))
        guard let sanitizedData = sanitized.data(using: .utf8) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: sanitizedData) as? [String: Any]
    }

    private static func stripJSONComments(from string: String) -> String {
        var output = ""
        var index = string.startIndex
        var isInsideString = false
        var isEscaping = false
        var isLineComment = false
        var isBlockComment = false

        while index < string.endIndex {
            let character = string[index]
            let nextIndex = string.index(after: index)
            let nextCharacter = nextIndex < string.endIndex ? string[nextIndex] : nil

            if isLineComment {
                if character == "\n" {
                    isLineComment = false
                    output.append(character)
                }
                index = nextIndex
                continue
            }

            if isBlockComment {
                if character == "\n" {
                    output.append(character)
                } else if character == "*", nextCharacter == "/" {
                    isBlockComment = false
                    index = string.index(after: nextIndex)
                    continue
                }
                index = nextIndex
                continue
            }

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", nextCharacter == "/" {
                isLineComment = true
                index = string.index(after: nextIndex)
                continue
            }

            if character == "/", nextCharacter == "*" {
                isBlockComment = true
                index = string.index(after: nextIndex)
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return output
    }

    private static func removeTrailingCommas(from string: String) -> String {
        let characters = Array(string)
        var output = ""
        var index = 0
        var isInsideString = false
        var isEscaping = false

        while index < characters.count {
            let character = characters[index]

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                index += 1
                continue
            }

            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace {
                    lookahead += 1
                }

                if lookahead < characters.count, characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return output
    }
}

struct HookInstaller {
    private static let preferredTargetsDefaultsKey = "HookInstaller.preferredTargets.v1"
    private static let qoderMigrationDefaultsKey = "HookInstaller.preferredTargets.qoder-default.v1"
    private static let qoderWorkMigrationDefaultsKey = "HookInstaller.preferredTargets.qoderwork-default.v1"
    private static let installedVersionDefaultsKey = "HookInstaller.installedVersion.v1"
    private static let firstLaunchDefaultsKey = "HookInstaller.isFirstLaunch.v1"
    private static let supportDirectoryName = ".ping-island"
    private static let bridgeLauncherName = "ping-island-bridge"
    private static let bridgeBinaryName = "PingIslandBridge"
    private static let legacyBridgeBinaryName = "IslandBridge"

    private static var defaultPreferredTargets: Set<String> {
        Set(
            ClientProfileRegistry.managedHookProfiles
                .filter { $0.defaultEnabled && canManage($0) }
                .map(\.id)
        )
    }

    /// Install managed hooks for preferred clients on app launch.
    static func installIfNeeded() {
        // Check if this is first launch and perform auto-integration
        let isFirstLaunch = checkAndMarkFirstLaunch()

        let preferredTargets = preferredTargets()
        installBridgeLauncherIfNeeded()
        removeLegacyTraeHooks()

        for profile in ClientProfileRegistry.managedHookProfiles {
            // For first launch, auto-install all defaultEnabled profiles
            if isFirstLaunch && profile.defaultEnabled && canManage(profile) {
                install(profile, persistPreference: true)
            } else if preferredTargets.contains(profile.id) && canManage(profile) {
                install(profile, persistPreference: false)
            } else {
                uninstall(profile, persistPreference: false)
            }
        }

        // Update version metadata after installation
        updateVersionMetadata()
    }

    /// Check if this is the first launch and mark as installed
    private static func checkAndMarkFirstLaunch() -> Bool {
        let defaults = UserDefaults.standard

        // Check if we've already recorded a version
        if defaults.string(forKey: installedVersionDefaultsKey) != nil {
            return false
        }

        // First launch - mark it
        defaults.set(true, forKey: firstLaunchDefaultsKey)
        return true
    }

    /// Update version metadata for tracking updates
    private static func updateVersionMetadata() {
        let defaults = UserDefaults.standard
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let versionMetadata: [String: Any] = [
            "version": currentVersion,
            "build": currentBuild,
            "installedAt": ISO8601DateFormatter().string(from: Date()),
            "previousVersion": defaults.string(forKey: installedVersionDefaultsKey) ?? ""
        ]

        defaults.set(currentVersion, forKey: installedVersionDefaultsKey)
        defaults.set(versionMetadata, forKey: "HookInstaller.versionMetadata.v1")
    }

    /// Get the installed version metadata
    static func getVersionMetadata() -> [String: Any]? {
        return UserDefaults.standard.dictionary(forKey: "HookInstaller.versionMetadata.v1")
    }

    /// Check if this is a fresh install (never installed before)
    static func isFreshInstall() -> Bool {
        return UserDefaults.standard.string(forKey: installedVersionDefaultsKey) == nil
    }

    /// Get the current installed version
    static func getInstalledVersion() -> String? {
        return UserDefaults.standard.string(forKey: installedVersionDefaultsKey)
    }

    static func install(_ profile: ManagedHookClientProfile) {
        install(profile, persistPreference: true)
    }

    static func createTemporarySettingsFile(for profileID: String) -> URL? {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: profileID) else {
            return nil
        }

        installBridgeLauncherIfNeeded()

        let directory = islandSupportDirectory()
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("native-runtime-hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(profile.id)-\(UUID().uuidString).json")
        let command = bridgeCommand(source: profile.bridgeSource, extraArguments: profile.bridgeExtraArguments)
        var hooks: [String: Any] = [:]
        for event in profile.events {
            hooks[event.name] = makeHookEntries(command: command, event: event)
        }
        writeJSONObject(["hooks": hooks], to: fileURL)
        return fileURL
    }

    static func removeTemporarySettingsFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func reinstall(_ profile: ManagedHookClientProfile) {
        uninstall(profile, persistPreference: false)
        install(profile, persistPreference: true)
    }

    static func uninstall(_ profile: ManagedHookClientProfile) {
        uninstall(profile, persistPreference: true)
    }

    /// Check if any managed hooks are currently installed.
    static func isInstalled() -> Bool {
        ClientProfileRegistry.managedHookProfiles.contains { isInstalled($0) }
    }

    static func isInstalled(_ profile: ManagedHookClientProfile) -> Bool {
        switch profile.installationKind {
        case .jsonHooks:
            return profile.configurationURLs.contains { containsManagedHooks(at: $0) }
        case .pluginFile:
            return profile.configurationURLs.contains { containsManagedPlugin(at: $0, profile: profile) }
                && isManagedPluginEnabled(profile)
        case .pluginDirectory:
            return profile.configurationURLs.contains { containsManagedPluginDirectory(at: $0, profile: profile) }
        case .hookDirectory:
            return profile.configurationURLs.contains { containsManagedHookDirectory(at: $0, profile: profile) }
                && isInternalHookEnabled(profile)
        }
    }

    /// Uninstall hooks for all managed targets.
    static func uninstall() {
        for profile in ClientProfileRegistry.managedHookProfiles {
            uninstall(profile, persistPreference: false)
        }
        persistPreferredTargets(Set<String>())
    }

    private static func install(_ profile: ManagedHookClientProfile, persistPreference: Bool) {
        if persistPreference {
            var targets = preferredTargets()
            targets.insert(profile.id)
            persistPreferredTargets(targets)
        }

        if profile.id == "claude-hooks" {
            removeLegacyClaudeScriptIfNeeded()
        }

        guard canManage(profile) else {
            return
        }

        installBridgeLauncherIfNeeded()
        switch profile.installationKind {
        case .jsonHooks:
            for url in installationTargets(for: profile) {
                updateHooks(at: url, profile: profile)
            }
        case .pluginFile:
            for url in installationTargets(for: profile) {
                writeManagedPlugin(at: url, profile: profile)
            }
            setManagedPluginEnabled(true, for: profile)
        case .pluginDirectory:
            for url in installationTargets(for: profile) {
                writeManagedPluginDirectory(at: url, profile: profile)
            }
        case .hookDirectory:
            for url in installationTargets(for: profile) {
                writeManagedHookDirectory(at: url, profile: profile)
            }
            setInternalHookEnabled(true, for: profile)
        }
    }

    private static func uninstall(_ profile: ManagedHookClientProfile, persistPreference: Bool) {
        if persistPreference {
            var targets = preferredTargets()
            targets.remove(profile.id)
            persistPreferredTargets(targets)
        }

        if profile.id == "claude-hooks" {
            removeLegacyClaudeScriptIfNeeded()
        }

        switch profile.installationKind {
        case .jsonHooks:
            for url in profile.configurationURLs {
                removeManagedHooks(at: url)
            }
        case .pluginFile:
            for url in profile.configurationURLs {
                removeManagedPlugin(at: url, profile: profile)
            }
            setManagedPluginEnabled(false, for: profile)
        case .pluginDirectory:
            for url in profile.configurationURLs {
                removeManagedPluginDirectory(at: url, profile: profile)
            }
        case .hookDirectory:
            for url in profile.configurationURLs {
                removeManagedHookDirectory(at: url, profile: profile)
            }
            setInternalHookEnabled(false, for: profile)
        }
    }

    private static func canManage(_ profile: ManagedHookClientProfile) -> Bool {
        profile.alwaysVisibleInSettings
            || ClientAppLocator.isInstalled(bundleIdentifiers: profile.localAppBundleIdentifiers)
    }

    private static func preferredTargets() -> Set<String> {
        guard let values = UserDefaults.standard.array(forKey: preferredTargetsDefaultsKey) as? [String] else {
            return defaultPreferredTargets
        }

        var targets = Set(values.compactMap { value in
            ClientProfileRegistry.managedHookProfile(id: value)?.id
        })

        if !UserDefaults.standard.bool(forKey: qoderMigrationDefaultsKey) {
            if let qoderProfile = ClientProfileRegistry.managedHookProfile(id: "qoder-hooks"),
               canManage(qoderProfile) {
                targets.insert(qoderProfile.id)
                persistPreferredTargets(targets)
            }
            UserDefaults.standard.set(true, forKey: qoderMigrationDefaultsKey)
        }

        if !UserDefaults.standard.bool(forKey: qoderWorkMigrationDefaultsKey) {
            if let qoderWorkProfile = ClientProfileRegistry.managedHookProfile(id: "qoderwork-hooks"),
               canManage(qoderWorkProfile) {
                targets.insert(qoderWorkProfile.id)
                persistPreferredTargets(targets)
            }
            UserDefaults.standard.set(true, forKey: qoderWorkMigrationDefaultsKey)
        }

        return targets.isEmpty ? [] : targets
    }

    private static func persistPreferredTargets(_ targets: Set<String>) {
        let values = targets.sorted()
        UserDefaults.standard.set(values, forKey: preferredTargetsDefaultsKey)
    }

    private static func installationTargets(for profile: ManagedHookClientProfile) -> [URL] {
        let existingTargets = profile.configurationURLs.filter { url in
            let fileManager = FileManager.default
            return fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: url.deletingLastPathComponent().path)
        }

        return existingTargets.isEmpty ? [profile.primaryConfigurationURL] : existingTargets
    }

    private static func isInternalHookEnabled(_ profile: ManagedHookClientProfile) -> Bool {
        guard let url = profile.activationConfigurationURL,
              let entryName = profile.activationEntryName,
              let data = try? Data(contentsOf: url) else {
            return false
        }
        return isInternalHookEnabled(existingData: data, entryName: entryName)
    }

    private static func isManagedPluginEnabled(_ profile: ManagedHookClientProfile) -> Bool {
        guard let url = profile.activationConfigurationURL,
              let data = try? Data(contentsOf: url) else {
            return false
        }
        return isManagedPluginEnabled(
            existingData: data,
            pluginURL: profile.primaryConfigurationURL
        )
    }

    private static func setInternalHookEnabled(_ enabled: Bool, for profile: ManagedHookClientProfile, customConfigURL: URL? = nil) {
        guard let entryName = profile.activationEntryName else {
            return
        }

        let url = customConfigURL ?? profile.activationConfigurationURL
        guard let url else {
            return
        }

        let existingData = try? Data(contentsOf: url)
        let data = updatedInternalHookConfigurationData(
            existingData: existingData,
            entryName: entryName,
            installing: enabled
        )
        writeData(data, to: url)
    }

    private static func setManagedPluginEnabled(
        _ enabled: Bool,
        for profile: ManagedHookClientProfile,
        customConfigURL: URL? = nil,
        pluginURL: URL? = nil
    ) {
        let url = customConfigURL ?? profile.activationConfigurationURL
        let pluginURL = pluginURL ?? profile.primaryConfigurationURL
        guard let url else {
            return
        }

        let existingData = try? Data(contentsOf: url)
        let data = updatedConfigurationData(
            existingData: existingData,
            profile: profile,
            customCommand: "",
            installing: enabled,
            pluginURL: pluginURL
        )
        writeData(data, to: url)
    }

    private static func removeLegacyClaudeScriptIfNeeded() {
        let legacyScriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("hooks")
            .appendingPathComponent("island-state.py")
        try? FileManager.default.removeItem(at: legacyScriptURL)
    }

    private static func removeLegacyTraeHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyPaths = [
            "Library/Application Support/Trae/User/settings.json",
            "Library/Application Support/Trae CN/User/settings.json",
            ".trae/settings.json"
        ]

        for path in legacyPaths {
            let url = path
                .split(separator: "/")
                .reduce(home) { partialURL, component in
                    partialURL.appendingPathComponent(String(component))
                }
            removeManagedHooks(at: url)
        }
    }

    private static func removeManagedHooks(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              var json = HookConfigParser.parseJSONObject(from: data),
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    isIslandManagedHookEntry(entry)
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
        writeJSONObject(json, to: url)
    }

    private static func installBridgeLauncherIfNeeded() {
        let binDirectory = islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
        let launcherURL = binDirectory.appendingPathComponent(bridgeLauncherName)

        try? FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )

        installBridgeBinaryIfNeeded(in: binDirectory)

        guard !FileManager.default.fileExists(atPath: launcherURL.path) else {
            return
        }

        let bundleBridge = (Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(bridgeBinaryName)
            .path) ?? ""
        let legacyBundleBridge = (Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(legacyBridgeBinaryName)
            .path) ?? ""

        let script = """
        #!/bin/zsh
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        candidates=(
          "$SCRIPT_DIR/\(bridgeBinaryName)"
          "$SCRIPT_DIR/\(legacyBridgeBinaryName)"
          "\(bundleBridge)"
          "\(legacyBundleBridge)"
        )

        for candidate in "${candidates[@]}"; do
          if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            exec "$candidate" "$@"
          fi
        done

        echo "\(bridgeBinaryName) binary not found" >&2
        exit 127
        """

        try? Data(script.utf8).write(to: launcherURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherURL.path
        )
    }

    private static func installBridgeBinaryIfNeeded(in binDirectory: URL) {
        let bundledBridgeURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(bridgeBinaryName)

        guard let bundledBridgeURL,
              FileManager.default.isReadableFile(atPath: bundledBridgeURL.path) else {
            return
        }

        let destinationURL = binDirectory.appendingPathComponent(bridgeBinaryName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let matchesExistingBinary =
                (try? Data(contentsOf: bundledBridgeURL)) == (try? Data(contentsOf: destinationURL))
            if matchesExistingBinary == true {
                return
            }

            try? FileManager.default.removeItem(at: destinationURL)
        }

        try? FileManager.default.copyItem(at: bundledBridgeURL, to: destinationURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destinationURL.path
        )
    }

    private static func normalizedHookEntries(
        _ existingEntries: [[String: Any]]?,
        preferred: [[String: Any]]
    ) -> [[String: Any]] {
        let preservedEntries = (existingEntries ?? []).filter { !isIslandManagedHookEntry($0) }

        return preservedEntries + preferred
    }

    private static func updateHooks(at url: URL, profile: ManagedHookClientProfile) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = HookConfigParser.parseJSONObject(from: data) {
            json = existing
        }

        if profile.brand == .copilot {
            // GitHub Copilot expects flat command entries and does not include the
            // hook event name in stdin, so we bind the event explicitly here.
            json["version"] = 1
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            for event in profile.events {
                let command = bridgeCommand(
                    source: profile.bridgeSource,
                    extraArguments: profile.bridgeExtraArguments + ["--event", event.name]
                )
                let existingEvent = hooks[event.name] as? [[String: Any]]
                hooks[event.name] = normalizedHookEntries(
                    existingEvent,
                    preferred: makeCopilotHookEntries(command: command, event: event)
                )
            }
            json["hooks"] = hooks
            writeJSONObject(json, to: url)
            return
        }

        let command = bridgeCommand(source: profile.bridgeSource, extraArguments: profile.bridgeExtraArguments)

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for event in profile.events {
            let existingEvent = hooks[event.name] as? [[String: Any]]
            hooks[event.name] = normalizedHookEntries(
                existingEvent,
                preferred: makeHookEntries(command: command, event: event)
            )
        }

        json["hooks"] = hooks
        writeJSONObject(json, to: url)
    }

    private static func writeManagedPlugin(at url: URL, profile: ManagedHookClientProfile) {
        let content = managedPluginSource(for: profile)
        guard !content.isEmpty else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try? Data(content.utf8).write(to: url, options: .atomic)
    }

    private static func removeManagedPlugin(at url: URL, profile: ManagedHookClientProfile) {
        guard containsManagedPlugin(at: url, profile: profile) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private static func containsManagedPlugin(at url: URL, profile: ManagedHookClientProfile) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }

        return content.contains(managedMarker(for: profile))
    }

    private static func writeManagedPluginDirectory(at url: URL, profile: ManagedHookClientProfile) {
        let files = managedPluginDirectoryFiles(for: profile)
        guard !files.isEmpty else { return }

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = url.appendingPathComponent(name)
            try? Data(content.utf8).write(to: fileURL, options: .atomic)
        }
    }

    private static func removeManagedPluginDirectory(at url: URL, profile: ManagedHookClientProfile) {
        guard containsManagedPluginDirectory(at: url, profile: profile) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private static func containsManagedPluginDirectory(at url: URL, profile: ManagedHookClientProfile) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        let marker = managedMarker(for: profile)
        let candidates = [
            url.appendingPathComponent("plugin.yaml"),
            url.appendingPathComponent("__init__.py")
        ]

        return candidates.contains { fileURL in
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return content.contains(marker)
        }
    }

    private static func writeManagedHookDirectory(at url: URL, profile: ManagedHookClientProfile) {
        let files = managedHookDirectoryFiles(for: profile)
        guard !files.isEmpty else { return }

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = url.appendingPathComponent(name)
            try? Data(content.utf8).write(to: fileURL, options: .atomic)
        }
    }

    private static func removeManagedHookDirectory(at url: URL, profile: ManagedHookClientProfile) {
        guard containsManagedHookDirectory(at: url, profile: profile) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private static func containsManagedHookDirectory(at url: URL, profile: ManagedHookClientProfile) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        let marker = managedMarker(for: profile)
        let candidates = [
            url.appendingPathComponent("HOOK.md"),
            url.appendingPathComponent("handler.ts")
        ]

        return candidates.contains { fileURL in
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return content.contains(marker)
        }
    }

    private static func makeHookEntries(command: String, event: HookInstallEventDescriptor) -> [[String: Any]] {
        var hookCommand: [String: Any] = [
            "type": "command",
            "command": command
        ]
        if let timeout = event.timeout {
            hookCommand["timeout"] = timeout
        }

        return event.templates.map { template in
            switch template {
            case .plain:
                return ["hooks": [hookCommand]]
            case .matcher(let matcher):
                return [
                    "matcher": matcher,
                    "hooks": [hookCommand]
                ]
            }
        }
    }

    private static func makeCopilotHookEntries(command: String, event: HookInstallEventDescriptor) -> [[String: Any]] {
        var entry: [String: Any] = [
            "type": "command",
            "bash": command
        ]
        if let timeout = event.timeout {
            entry["timeoutSec"] = timeout
        }
        return [entry]
    }

    private static func islandSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    private static func bridgeCommandArguments(for profile: ManagedHookClientProfile) -> [String] {
        [
            islandSupportDirectory()
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(bridgeLauncherName)
                .path,
            "--source",
            profile.bridgeSource
        ] + profile.bridgeExtraArguments
    }

    private static func bridgeCommand(source: String, extraArguments: [String] = []) -> String {
        let base = islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(bridgeLauncherName)
            .path + " --source \(source)"
        guard !extraArguments.isEmpty else { return base }
        return ([base] + extraArguments).joined(separator: " ")
    }

    private static func containsManagedHooks(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = HookConfigParser.parseJSONObject(from: data),
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if isIslandManagedHookEntry(entry) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func isIslandManagedHookEntry(_ entry: [String: Any]) -> Bool {
        if let command = hookCommandString(from: entry) {
            return isIslandManagedHookCommand(command)
        }

        if let nestedHooks = entry["hooks"] as? [[String: Any]] {
            return nestedHooks.contains { hook in
                guard let command = hookCommandString(from: hook) else { return false }
                return isIslandManagedHookCommand(command)
            }
        }

        return false
    }

    private static func hookCommandString(from entry: [String: Any]) -> String? {
        let candidates = [
            entry["command"] as? String,
            entry["bash"] as? String,
            entry["powershell"] as? String
        ]
        return candidates.compactMap { command in
            let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }.first
    }

    private static func isIslandManagedHookCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("island-state.py")
            || normalized.contains("/.ping-island/bin/ping-island-bridge")
            || normalized.contains("/.ping-island/bin/island-bridge")
    }

    private static func managedMarker(for profile: ManagedHookClientProfile) -> String {
        "Ping Island managed integration: \(profile.id)"
    }

    static func managedPluginSource(for profile: ManagedHookClientProfile) -> String {
        guard profile.id == "opencode-hooks" else {
            return ""
        }

        let argsData = (try? JSONSerialization.data(withJSONObject: bridgeCommandArguments(for: profile), options: []))
            ?? Data("[]".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let marker = managedMarker(for: profile)

        return """
        // \(marker)
        // Generated by Ping Island. Reinstall from Island settings if you need to refresh it.

        const BRIDGE_ARGS = \(argsJSON);
        const ENV_KEYS = [
          "TERM_PROGRAM",
          "ITERM_SESSION_ID",
          "TERM_SESSION_ID",
          "TMUX",
          "TMUX_PANE",
          "KITTY_WINDOW_ID",
          "__CFBundleIdentifier",
          "CONDUCTOR_WORKSPACE_NAME",
          "CONDUCTOR_PORT",
          "CURSOR_TRACE_ID",
          "CMUX_WORKSPACE_ID",
          "CMUX_SURFACE_ID",
          "CMUX_SOCKET_PATH",
          "WINDOWSERVER_DISPLAY_UUID"
        ];

        function isObject(value) {
          return value !== null && typeof value === "object" && !Array.isArray(value);
        }

        function atPath(value, path) {
          let current = value;
          for (const key of path) {
            if (!isObject(current) && !Array.isArray(current)) return undefined;
            current = current?.[key];
          }
          return current;
        }

        function firstDefined(value, paths) {
          for (const path of paths) {
            const candidate = atPath(value, path);
            if (candidate !== undefined && candidate !== null && candidate !== "") {
              return candidate;
            }
          }
          return undefined;
        }

        function firstString(value, keys, depth = 0) {
          if (depth > 5 || value == null) return undefined;
          if (typeof value === "string" && value.trim().length > 0) return value;
          if (Array.isArray(value)) {
            for (const entry of value) {
              const found = firstString(entry, keys, depth + 1);
              if (found) return found;
            }
            return undefined;
          }
          if (!isObject(value)) return undefined;

          for (const key of keys) {
            const candidate = value[key];
            if (typeof candidate === "string" && candidate.trim().length > 0) {
              return candidate;
            }
          }

          for (const nested of Object.values(value)) {
            const found = firstString(nested, keys, depth + 1);
            if (found) return found;
          }
          return undefined;
        }

        function firstObject(value, keys, depth = 0) {
          if (depth > 5 || value == null) return undefined;
          if (Array.isArray(value)) {
            for (const entry of value) {
              const found = firstObject(entry, keys, depth + 1);
              if (found) return found;
            }
            return undefined;
          }
          if (!isObject(value)) return undefined;

          for (const key of keys) {
            const candidate = value[key];
            if (isObject(candidate) || Array.isArray(candidate)) {
              return candidate;
            }
          }

          for (const nested of Object.values(value)) {
            const found = firstObject(nested, keys, depth + 1);
            if (found) return found;
          }
          return undefined;
        }

        function stableString(value) {
          if (value == null) return undefined;
          if (typeof value === "string") {
            const trimmed = value.trim();
            return trimmed.length > 0 ? trimmed : undefined;
          }
          try {
            return JSON.stringify(value);
          } catch {
            return undefined;
          }
        }

        function capitalize(value) {
          if (typeof value !== "string" || value.length === 0) return undefined;
          return value.charAt(0).toUpperCase() + value.slice(1);
        }

        function collectBridgeEnv() {
          const collected = {};
          for (const key of ENV_KEYS) {
            const value = process.env[key];
            if (typeof value === "string" && value.length > 0) {
              collected[key] = value;
            }
          }
          return collected;
        }

        function detectTTY() {
          try {
            const { execSync } = require("child_process");
            let walkPid = process.pid;
            for (let index = 0; index < 8; index += 1) {
              const info = execSync(`ps -o tty=,ppid= -p ${walkPid}`, { timeout: 1000 })
                .toString()
                .trim();
              if (!info) break;
              const parts = info.split(/\\s+/);
              const tty = parts[0];
              const ppid = Number.parseInt(parts[1] || "", 10);
              if (tty && tty !== "??" && tty !== "?") {
                return tty.startsWith("/dev/") ? tty : `/dev/${tty}`;
              }
              if (!Number.isFinite(ppid) || ppid <= 1) break;
              walkPid = ppid;
            }
          } catch {
            return undefined;
          }
          return undefined;
        }

        function makeBasePayload(sessionId, extra = {}) {
          return {
            session_id: sessionId,
            _source: "opencode",
            _env: collectBridgeEnv(),
            _tty: detectedTTY,
            pid: process.pid,
            ...extra
          };
        }

        function normalizeQuestions(questions) {
          if (!Array.isArray(questions)) return [];
          return questions.map((question) => ({
            id: stableString(question?.id),
            header: stableString(question?.header),
            question: stableString(question?.question),
            description: stableString(question?.description),
            options: Array.isArray(question?.options)
              ? question.options
                  .map((option) => {
                    if (typeof option === "string") return option;
                    if (!isObject(option)) return undefined;
                    const label = stableString(option.label);
                    if (!label) return undefined;
                    return {
                      label,
                      description: stableString(option.description)
                    };
                  })
                  .filter(Boolean)
              : [],
            multiple: question?.multiple === true
          })).filter((question) => question.question);
        }

        function questionAnswerArrays(questions, answers) {
          if (!isObject(answers)) return [];
          const mappedAnswers = questions
            .map((question, index) => {
              const lookupKeys = [
                stableString(question.id),
                stableString(question.question),
                stableString(question.header),
                String(index)
              ].filter(Boolean);

              const value = lookupKeys
                .map((key) => answers[key])
                .find((candidate) => candidate !== undefined && candidate !== null);
              if (value === undefined || value === null) return [];

              if (Array.isArray(value)) {
                return value
                  .map((entry) => stableString(entry))
                  .filter(Boolean);
              }

              const normalized = stableString(value);
              return normalized ? [normalized] : [];
            })
            .filter((entry) => entry.length > 0);

          if (mappedAnswers.length > 0) return mappedAnswers;
          return Object.values(answers)
            .map((value) => {
              if (Array.isArray(value)) {
                return value
                  .map((entry) => stableString(entry))
                  .filter(Boolean);
              }
              const normalized = stableString(value);
              return normalized ? [normalized] : [];
            })
            .filter((entry) => entry.length > 0);
        }

        function toolNameForPermission(permission) {
          if (permission === "bash") return "Bash";
          if (permission === "edit" || permission === "write") return "Write";
          return capitalize(permission) ?? "Permission";
        }

        function permissionToolInput(properties) {
          const patterns = Array.isArray(properties?.patterns)
            ? properties.patterns.map((entry) => stableString(entry)).filter(Boolean)
            : [];
          const input = {};
          if (patterns.length > 0) {
            input.patterns = patterns;
          }
          if (isObject(properties?.metadata)) {
            input.metadata = properties.metadata;
          }
          if (properties?.permission === "bash" && patterns.length > 0) {
            input.command = patterns.join(" && ");
          }
          if ((properties?.permission === "edit" || properties?.permission === "write") && patterns.length > 0) {
            input.file_path = patterns[0];
          }
          return Object.keys(input).length > 0 ? input : undefined;
        }

        function mapEvent(event) {
          const type = event?.type;
          const properties = isObject(event?.properties) ? event.properties : {};
          if (typeof type !== "string" || type.length === 0) return undefined;

          if (type === "session.created" && isObject(properties.info) && stableString(properties.info.id)) {
            const rawSessionID = stableString(properties.info.id);
            const cwd = stableString(properties.info.directory);
            const sessionId = `opencode-${rawSessionID}`;
            const session = getSession(rawSessionID);
            session.cwd = cwd;
            return makeBasePayload(sessionId, {
              hook_event_name: "SessionStart",
              cwd
            });
          }

          if (type === "session.deleted" && isObject(properties.info) && stableString(properties.info.id)) {
            const rawSessionID = stableString(properties.info.id);
            sessions.delete(rawSessionID);
            messageRoles.forEach((value, key) => {
              if (value?.sessionID === rawSessionID) {
                messageRoles.delete(key);
              }
            });
            return makeBasePayload(`opencode-${rawSessionID}`, {
              hook_event_name: "SessionEnd"
            });
          }

          if (type === "session.updated" && isObject(properties.info) && stableString(properties.info.id)) {
            const rawSessionID = stableString(properties.info.id);
            const session = getSession(rawSessionID);
            const cwd = stableString(properties.info.directory) ?? session.cwd;
            if (cwd) session.cwd = cwd;
            const title = stableString(properties.info.title);
            if (title && !title.startsWith("New session")) {
              session.pendingTitle = title;
            }
            if (properties.info.time?.archived) {
              sessions.delete(rawSessionID);
              return makeBasePayload(`opencode-${rawSessionID}`, {
                hook_event_name: "SessionEnd",
                cwd
              });
            }
            return undefined;
          }

          if (type === "session.status" && stableString(properties.sessionID)) {
            const rawSessionID = stableString(properties.sessionID);
            const session = getSession(rawSessionID);
            if (properties.status?.type === "idle") {
              const payload = makeBasePayload(`opencode-${rawSessionID}`, {
                hook_event_name: "Stop",
                cwd: session.cwd,
                last_assistant_message: session.lastAssistantText || undefined,
                session_title: session.pendingTitle || undefined
              });
              session.pendingTitle = undefined;
              return payload;
            }
            return undefined;
          }

          if (type === "message.updated" && isObject(properties.info) && stableString(properties.info.id) && stableString(properties.info.sessionID)) {
            messageRoles.set(stableString(properties.info.id), {
              role: stableString(properties.info.role),
              sessionID: stableString(properties.info.sessionID)
            });
            if (messageRoles.size > 200) {
              messageRoles.delete(messageRoles.keys().next().value);
            }
            return undefined;
          }

          if (type === "message.part.updated" && isObject(properties.part) && stableString(properties.part.sessionID)) {
            const rawSessionID = stableString(properties.part.sessionID);
            const session = getSession(rawSessionID);
            const sessionId = `opencode-${rawSessionID}`;

            if (properties.part.type === "text" && stableString(properties.part.messageID)) {
              const meta = messageRoles.get(stableString(properties.part.messageID));
              if (!meta) return undefined;

              const text = stableString(properties.part.text);
              if (!text) return undefined;

              if (meta.role === "user") {
                session.lastUserText = text;
                return makeBasePayload(sessionId, {
                  hook_event_name: "UserPromptSubmit",
                  cwd: session.cwd,
                  prompt: text
                });
              }

              if (meta.role === "assistant") {
                session.lastAssistantText = text;
              }
              return undefined;
            }

            if (properties.part.type === "tool") {
              const toolName = capitalize(stableString(properties.part.tool)) ?? "Tool";
              const toolInput = properties.part.state?.input;
              const state = stableString(properties.part.state?.status);
              if (state === "running" || state === "pending") {
                return makeBasePayload(sessionId, {
                  hook_event_name: "PreToolUse",
                  cwd: session.cwd,
                  tool_name: toolName,
                  tool_input: isObject(toolInput) || Array.isArray(toolInput) ? toolInput : undefined
                });
              }
              if (state === "completed" || state === "error") {
                return makeBasePayload(sessionId, {
                  hook_event_name: "PostToolUse",
                  cwd: session.cwd,
                  tool_name: toolName,
                  tool_input: isObject(toolInput) || Array.isArray(toolInput) ? toolInput : undefined
                });
              }
            }
          }

          if (type === "permission.asked" && stableString(properties.id) && stableString(properties.sessionID)) {
            const rawSessionID = stableString(properties.sessionID);
            const session = getSession(rawSessionID);
            return makeBasePayload(`opencode-${rawSessionID}`, {
              hook_event_name: "PermissionRequest",
              cwd: session.cwd,
              tool_name: toolNameForPermission(properties.permission),
              tool_input: permissionToolInput(properties),
              _opencode_request_id: stableString(properties.id)
            });
          }

          if (type === "permission.replied" && stableString(properties.sessionID)) {
            const rawSessionID = stableString(properties.sessionID);
            const session = getSession(rawSessionID);
            return makeBasePayload(`opencode-${rawSessionID}`, {
              hook_event_name: "PostToolUse",
              cwd: session.cwd,
              tool_name: toolNameForPermission(properties.permission)
            });
          }

          if (type === "question.asked" && stableString(properties.id) && stableString(properties.sessionID)) {
            const rawSessionID = stableString(properties.sessionID);
            const session = getSession(rawSessionID);
            return makeBasePayload(`opencode-${rawSessionID}`, {
              hook_event_name: "PreToolUse",
              cwd: session.cwd,
              tool_name: "AskUserQuestion",
              tool_input: { questions: normalizeQuestions(properties.questions) },
              _opencode_request_id: stableString(properties.id)
            });
          }

          if ((type === "question.replied" || type === "question.rejected") && stableString(properties.sessionID)) {
            const rawSessionID = stableString(properties.sessionID);
            const session = getSession(rawSessionID);
            return makeBasePayload(`opencode-${rawSessionID}`, {
              hook_event_name: "PostToolUse",
              cwd: session.cwd,
              tool_name: "AskUserQuestion"
            });
          }

          return undefined;
        }

        async function runBridge(payload, captureResponse = false) {
          const env = { ...(globalThis.process?.env ?? {}) };
          if (isObject(payload?._env)) {
            Object.assign(env, payload._env);
          }
          if (typeof payload?._tty === "string" && payload._tty.length > 0) {
            env.TTY = payload._tty;
          }

          try {
            const subprocess = Bun.spawn(BRIDGE_ARGS, {
              stdin: new Response(JSON.stringify(payload)),
              stdout: captureResponse ? "pipe" : "ignore",
              stderr: "ignore",
              env
            });

            const exitCode = await subprocess.exited;
            if (!captureResponse || exitCode !== 0 || !subprocess.stdout) {
              return null;
            }

            const stdout = (await new Response(subprocess.stdout).text()).trim();
            if (!stdout) return null;
            try {
              return JSON.parse(stdout);
            } catch {
              return null;
            }
          } catch {
            // OpenCode hooks should never fail because Island is unavailable.
            return null;
          }
        }

        const detectedTTY = detectTTY();
        const messageRoles = new Map();
        const sessions = new Map();

        function getSession(sessionID) {
          if (!sessions.has(sessionID)) {
            sessions.set(sessionID, {
              cwd: undefined,
              lastUserText: "",
              lastAssistantText: "",
              pendingTitle: undefined
            });
          }
          return sessions.get(sessionID);
        }

        export const server = async ({ client, serverUrl }) => {
          const internalFetch = client?._client?.getConfig?.()?.fetch ?? globalThis.fetch ?? null;
          const serverPort = Number.parseInt(serverUrl?.port || "", 10) || 4096;

          return {
          name: "Ping Island",
          description: "Forward OpenCode hook events to Ping Island.",
          event: async ({ event }) => {
            const payload = mapEvent(event);
            if (!payload) return;

            const requestId = stableString(payload._opencode_request_id);
            const questions = payload.tool_input?.questions;

            if (
              payload.hook_event_name === "PreToolUse"
                && payload.tool_name === "AskUserQuestion"
                && requestId
                && internalFetch
            ) {
              const response = await runBridge(payload, true);
              const answers = response?.hookSpecificOutput?.decision?.updatedInput?.answers
                ?? response?.hookSpecificOutput?.updatedInput?.answers;
              const answerArray = questionAnswerArrays(Array.isArray(questions) ? questions : [], answers);
              if (answerArray.length === 0) return;

              try {
                await internalFetch(new Request(`http://localhost:${serverPort}/question/${requestId}/reply`, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ answers: answerArray })
                }));
              } catch {
                // Ignore OpenCode reply failures so hooks never crash the session.
              }
              return;
            }

            if (payload.hook_event_name === "PermissionRequest" && requestId && internalFetch) {
              const response = await runBridge(payload, true);
              const behavior = stableString(response?.hookSpecificOutput?.decision?.behavior)
                ?? stableString(response?.hookSpecificOutput?.permissionDecision);
              const reason = stableString(response?.hookSpecificOutput?.decision?.message)
                ?? stableString(response?.hookSpecificOutput?.decision?.reason)
                ?? stableString(response?.hookSpecificOutput?.permissionDecisionReason);
              if (!behavior) return;

              const reply = behavior === "allow"
                ? "once"
                : behavior === "allow_for_session" || behavior === "always"
                  ? "always"
                  : "reject";

              try {
                await internalFetch(new Request(`http://localhost:${serverPort}/permission/${requestId}/reply`, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ reply, message: reason })
                }));
              } catch {
                // Ignore OpenCode reply failures so hooks never crash the session.
              }
              return;
            }

            await runBridge(payload, false);
          },
          "shell.env": async (_input, output) => {
            for (const key of ENV_KEYS) {
              const value = process.env[key];
              if (typeof value === "string" && value.length > 0) {
                output.env[key] = value;
              }
            }
            if (detectedTTY) {
              output.env.TTY = detectedTTY;
            }
          }
        };

        };

        export default server;
        """
    }

    static func managedPluginDirectoryFiles(for profile: ManagedHookClientProfile) -> [String: String] {
        guard profile.id == "hermes-hooks" else {
            return [:]
        }

        let argsData = (try? JSONSerialization.data(withJSONObject: bridgeCommandArguments(for: profile), options: []))
            ?? Data("[]".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let marker = managedMarker(for: profile)

        let pluginYAML = """
        # \(marker)
        name: ping-island
        version: 1.0.0
        description: Forward Hermes Agent plugin hooks to Ping Island
        provides:
          hooks: true
        """

        let initPy = """
        # \(marker)
        \"\"\"Ping Island Hermes plugin.

        Generated by Ping Island. Reinstall from Island settings if you need to refresh it.
        \"\"\"

        from __future__ import annotations

        import json
        import os
        import subprocess
        import threading

        BRIDGE_ARGS = \(argsJSON)
        ENV_KEYS = [
            "TERM_PROGRAM",
            "ITERM_SESSION_ID",
            "TERM_SESSION_ID",
            "TMUX",
            "TMUX_PANE",
            "KITTY_WINDOW_ID",
            "__CFBundleIdentifier",
            "CONDUCTOR_WORKSPACE_NAME",
            "CONDUCTOR_PORT",
            "CURSOR_TRACE_ID",
            "CMUX_WORKSPACE_ID",
            "CMUX_SURFACE_ID",
            "CMUX_SOCKET_PATH",
            "WINDOWSERVER_DISPLAY_UUID",
        ]
        _SESSION_STATE = {}


        def _stable_text(value):
            if value is None:
                return None
            if isinstance(value, str):
                stripped = value.strip()
                return stripped or None
            try:
                return json.dumps(value, ensure_ascii=False)
            except Exception:
                return None


        def _payload_session_id(raw_value):
            normalized = _stable_text(raw_value)
            if not normalized:
                return None
            return normalized if normalized.startswith("hermes-") else f"hermes-{normalized}"


        def _collect_env():
            collected = {}
            for key in ENV_KEYS:
                value = os.environ.get(key)
                if value:
                    collected[key] = value
            return collected


        def _detect_tty():
            for fd in (0, 1, 2):
                try:
                    value = os.ttyname(fd)
                except OSError:
                    continue
                if value:
                    return value
            return os.environ.get("TTY")


        def _state_for(session_id):
            if session_id not in _SESSION_STATE:
                _SESSION_STATE[session_id] = {
                    "cwd": None,
                    "last_user": None,
                    "last_assistant": None,
                }
            return _SESSION_STATE[session_id]


        def _resolve_session_id(*candidates, **kwargs):
            for candidate in candidates:
                resolved = _payload_session_id(candidate)
                if resolved:
                    return resolved
            for key in ("session_id", "task_id", "conversation_id"):
                resolved = _payload_session_id(kwargs.get(key))
                if resolved:
                    return resolved
            return None


        def _resolve_cwd(kwargs):
            for key in ("cwd", "working_directory", "directory"):
                resolved = _stable_text(kwargs.get(key))
                if resolved:
                    return resolved
            try:
                return os.getcwd()
            except OSError:
                return None


        def _extract_user_message(kwargs):
            direct = _stable_text(kwargs.get("user_message"))
            if direct:
                return direct

            messages = kwargs.get("messages")
            if isinstance(messages, list):
                for entry in reversed(messages):
                    if not isinstance(entry, dict):
                        continue
                    role = _stable_text(entry.get("role"))
                    if role != "user":
                        continue
                    content = entry.get("content")
                    if isinstance(content, str):
                        return _stable_text(content)
                    if isinstance(content, list):
                        for item in content:
                            if isinstance(item, dict) and item.get("type") == "text":
                                text = _stable_text(item.get("text"))
                                if text:
                                    return text
            return None


        def _extract_assistant_message(kwargs):
            direct = _stable_text(kwargs.get("assistant_response"))
            if direct:
                return direct

            response = kwargs.get("response")
            if isinstance(response, str):
                normalized = _stable_text(response)
                if normalized:
                    return normalized
            if isinstance(response, dict):
                for key in ("content", "text", "response", "message"):
                    normalized = _stable_text(response.get(key))
                    if normalized:
                        return normalized
            return None


        def _parse_tool_result(result):
            if isinstance(result, str):
                try:
                    parsed = json.loads(result)
                except Exception:
                    return None, None
                if isinstance(parsed, dict):
                    return parsed, _stable_text(parsed.get("error"))
                return None, None
            if isinstance(result, dict):
                return result, _stable_text(result.get("error"))
            return None, None


        def _bridge_payload(session_id, **payload):
            state = _state_for(session_id)
            cwd = payload.pop("cwd", None) or state.get("cwd")
            if cwd:
                state["cwd"] = cwd
            return {
                "session_id": session_id,
                "_env": _collect_env(),
                "_tty": _detect_tty(),
                "cwd": cwd,
                **payload,
            }


        def _spawn_bridge(payload):
            env = os.environ.copy()
            bridged_env = payload.pop("_env", None)
            tty = payload.pop("_tty", None)
            if isinstance(bridged_env, dict):
                env.update({key: value for key, value in bridged_env.items() if isinstance(value, str) and value})
            if tty and not env.get("TTY"):
                env["TTY"] = tty

            try:
                process = subprocess.Popen(
                    BRIDGE_ARGS,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    env=env,
                    start_new_session=True,
                )
                if process.stdin:
                    process.stdin.write(json.dumps(payload, ensure_ascii=False))
                    process.stdin.close()
            except Exception:
                return


        def _emit(payload):
            threading.Thread(target=_spawn_bridge, args=(payload,), daemon=True).start()


        def _on_session_start(session_id=None, platform=None, model=None, **kwargs):
            resolved_id = _resolve_session_id(session_id, **kwargs)
            if not resolved_id:
                return
            _emit(
                _bridge_payload(
                    resolved_id,
                    hook_event_name="SessionStart",
                    platform=_stable_text(platform),
                    model=_stable_text(model),
                    message=_extract_user_message(kwargs),
                    cwd=_resolve_cwd(kwargs),
                )
            )


        def _on_pre_llm_call(session_id=None, user_message=None, **kwargs):
            resolved_id = _resolve_session_id(session_id, kwargs.get("task_id"), **kwargs)
            if not resolved_id:
                return None

            prompt = _stable_text(user_message) or _extract_user_message(kwargs)
            if not prompt:
                return None

            _state_for(resolved_id)["last_user"] = prompt
            _emit(
                _bridge_payload(
                    resolved_id,
                    hook_event_name="UserPromptSubmit",
                    prompt=prompt,
                    cwd=_resolve_cwd(kwargs),
                )
            )
            return None


        def _on_pre_tool_call(tool_name=None, args=None, task_id=None, **kwargs):
            resolved_id = _resolve_session_id(task_id, kwargs.get("session_id"), **kwargs)
            if not resolved_id:
                return
            payload = _bridge_payload(
                resolved_id,
                hook_event_name="PreToolUse",
                tool_name=_stable_text(tool_name) or "Tool",
                tool_input=args if isinstance(args, dict) else None,
                cwd=_resolve_cwd(kwargs),
            )
            _emit(payload)


        def _on_post_tool_call(tool_name=None, args=None, result=None, task_id=None, **kwargs):
            resolved_id = _resolve_session_id(task_id, kwargs.get("session_id"), **kwargs)
            if not resolved_id:
                return

            parsed_result, error_text = _parse_tool_result(result)
            payload = _bridge_payload(
                resolved_id,
                hook_event_name="PostToolUseFailure" if error_text else "PostToolUse",
                tool_name=_stable_text(tool_name) or "Tool",
                tool_input=args if isinstance(args, dict) else None,
                tool_result=parsed_result,
                error=error_text,
                cwd=_resolve_cwd(kwargs),
            )
            _emit(payload)


        def _on_post_llm_call(session_id=None, assistant_response=None, **kwargs):
            resolved_id = _resolve_session_id(session_id, kwargs.get("task_id"), **kwargs)
            if not resolved_id:
                return
            reply = _stable_text(assistant_response) or _extract_assistant_message(kwargs)
            if reply:
                _state_for(resolved_id)["last_assistant"] = reply


        def _on_session_end(session_id=None, completed=None, interrupted=None, platform=None, model=None, **kwargs):
            resolved_id = _resolve_session_id(session_id, kwargs.get("task_id"), **kwargs)
            if not resolved_id:
                return

            state = _state_for(resolved_id)
            assistant = state.get("last_assistant") or _extract_assistant_message(kwargs)
            event_name = "SessionEnd" if completed else "Stop"
            payload = _bridge_payload(
                resolved_id,
                hook_event_name=event_name,
                last_assistant_message=assistant,
                platform=_stable_text(platform),
                model=_stable_text(model),
                completed=bool(completed),
                interrupted=bool(interrupted),
                cwd=_resolve_cwd(kwargs),
            )
            _emit(payload)

            if completed or interrupted:
                _SESSION_STATE.pop(resolved_id, None)


        def register(ctx):
            ctx.register_hook("on_session_start", _on_session_start)
            ctx.register_hook("pre_llm_call", _on_pre_llm_call)
            ctx.register_hook("pre_tool_call", _on_pre_tool_call)
            ctx.register_hook("post_tool_call", _on_post_tool_call)
            ctx.register_hook("post_llm_call", _on_post_llm_call)
            ctx.register_hook("on_session_end", _on_session_end)
        """

        return [
            "plugin.yaml": pluginYAML,
            "__init__.py": initPy,
        ]
    }

    static func managedHookDirectoryFiles(
        for profile: ManagedHookClientProfile,
        bridgeArguments: [String]? = nil,
        bridgeEnvironment: [String: String] = [:]
    ) -> [String: String] {
        guard profile.id == "openclaw-hooks" else {
            return [:]
        }

        let resolvedBridgeArguments = bridgeArguments ?? bridgeCommandArguments(for: profile)
        let argsData = (try? JSONSerialization.data(withJSONObject: resolvedBridgeArguments, options: []))
            ?? Data("[]".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let environmentData = (try? JSONSerialization.data(withJSONObject: bridgeEnvironment, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let environmentJSON = String(data: environmentData, encoding: .utf8) ?? "{}"
        let eventList = ["command", "message", "session"]
        let eventsData = (try? JSONSerialization.data(withJSONObject: eventList, options: []))
            ?? Data("[]".utf8)
        let eventsJSON = String(data: eventsData, encoding: .utf8) ?? "[]"
        let marker = managedMarker(for: profile)
        let hookName = profile.activationEntryName ?? profile.primaryConfigurationURL.lastPathComponent

        let hookMD = """
        ---
        name: \(hookName)
        description: "Forward OpenClaw internal hook events to Ping Island"
        metadata:
          { "openclaw": { "events": \(eventsJSON) } }
        ---

        <!-- \(marker) -->

        # Ping Island OpenClaw Hook

        Generated by Ping Island. Reinstall from Island settings if you need to refresh it.
        """

        let handlerTS = """
        // \(marker)
        // Generated by Ping Island. Reinstall from Island settings if you need to refresh it.

        const BRIDGE_ARGS = \(argsJSON);
        const BRIDGE_ENV = \(environmentJSON);

        function stableString(value) {
          if (value == null) return undefined;
          if (typeof value === "string") {
            const trimmed = value.trim();
            return trimmed.length > 0 ? trimmed : undefined;
          }
          try {
            return JSON.stringify(value);
          } catch {
            return undefined;
          }
        }

        function firstDefined(...values) {
          for (const value of values) {
            if (value !== undefined && value !== null && value !== "") {
              return value;
            }
          }
          return undefined;
        }

        function summarizeContent(content) {
          if (typeof content === "string") return content;
          if (Array.isArray(content)) {
            const parts = content
              .map((entry) => summarizeContent(entry))
              .filter(Boolean);
            return parts.length > 0 ? parts.join("\\n") : undefined;
          }
          if (content && typeof content === "object") {
            return firstDefined(
              summarizeContent(content.text),
              summarizeContent(content.body),
              summarizeContent(content.message),
              stableString(content)
            );
          }
          return undefined;
        }

        function statusFor(event) {
          const key = `${event?.type ?? ""}:${event?.action ?? ""}`;
          switch (key) {
            case "command:new":
            case "command:reset":
            case "message:received":
              return "thinking";
            case "message:sent":
              return "waitingForInput";
            case "command:stop":
              return "completed";
            case "session:compact:before":
              return "compacting";
            case "session:compact:after":
            case "session:patch":
              return "active";
            default:
              return "active";
          }
        }

        function titleFor(event) {
          return firstDefined(
            event?.context?.sessionEntry?.title,
            event?.context?.sessionEntry?.name,
            event?.context?.patch?.title,
            "OpenClaw"
          );
        }

        function previewFor(event) {
          return firstDefined(
            summarizeContent(event?.context?.content),
            summarizeContent(event?.context?.bodyForAgent),
            summarizeContent(event?.context?.transcript),
            summarizeContent(event?.context?.patch),
            event?.context?.commandSource,
            `${event?.type ?? "event"}:${event?.action ?? "unknown"}`
          );
        }

        function buildPayload(event) {
          const rawSessionId = firstDefined(
            event?.context?.sessionEntry?.id,
            event?.context?.sessionEntry?.sessionID,
            event?.context?.sessionEntry?.sessionId,
            event?.context?.patch?.sessionID,
            event?.context?.patch?.sessionId,
            event?.sessionKey,
            event?.sessionID,
            event?.sessionId,
            event?.context?.sessionKey,
            event?.context?.sessionID,
            event?.context?.sessionId
          );
          const sessionId = stableString(rawSessionId);
          if (!sessionId) {
            return {
              payload: undefined,
              skipReason: "missing_session_id",
              rawSessionId: stableString(rawSessionId)
            };
          }

          const payload = {
            event: `${event?.type ?? "unknown"}:${event?.action ?? "unknown"}`,
            session_id: sessionId,
            session_file_path: `${process.env.HOME ?? ""}/.openclaw/agents/main/sessions/${sessionId}.jsonl`,
            cwd: firstDefined(
              event?.context?.workspaceDir,
              event?.context?.workspace?.dir,
              event?.context?.directory,
              event?.context?.sessionEntry?.workspaceDir,
              event?.context?.sessionEntry?.directory,
              event?.context?.cfg?.workspace?.dir
            ),
            status: statusFor(event),
            title: titleFor(event),
            message: previewFor(event),
            client_kind: "openclaw",
            client_name: "OpenClaw",
            client_origin: "gateway",
            client_originator: "OpenClaw",
            thread_source: "openclaw-hooks"
          };

          return {
            payload: Object.fromEntries(
              Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== "")
            ),
            skipReason: undefined,
            rawSessionId: stableString(rawSessionId)
          };
        }

        async function forwardViaNode(payload) {
          const { spawn } = await import("node:child_process");
          const env = { ...(process?.env ?? {}), ...BRIDGE_ENV };
          return await new Promise((resolve, reject) => {
            const child = spawn(BRIDGE_ARGS[0], BRIDGE_ARGS.slice(1), {
              stdio: ["pipe", "ignore", "ignore"],
              env
            });
            child.once("error", reject);
            child.once("close", (code, signal) => {
              resolve({ code, signal });
            });
            child.stdin.on("error", () => {});
            child.stdin.write(JSON.stringify(payload));
            child.stdin.end();
          });
        }

        const handler = async (event) => {
          const { payload } = buildPayload(event);
          if (!payload) return;

          try {
            const env = { ...(globalThis.process?.env ?? {}), ...BRIDGE_ENV };
            if (typeof Bun !== "undefined" && typeof Bun.spawn === "function") {
              const subprocess = Bun.spawn(BRIDGE_ARGS, {
                stdin: new Response(JSON.stringify(payload)),
                stdout: "ignore",
                stderr: "ignore",
                env
              });
              void subprocess.exited.catch(() => {});
              return;
            }

            await forwardViaNode(payload);
          } catch {
            // OpenClaw hooks should never fail because Ping Island is unavailable.
          }
        };

        export default handler;
        """

        return [
            "HOOK.md": hookMD,
            "handler.ts": handlerTS
        ]
    }

    // MARK: - Custom Hook Installations

    private static let customInstallationsDefaultsKey = "HookInstaller.customInstallations.v1"

    struct CustomHookInstallation: Codable, Identifiable, Equatable {
        let id: String
        let profileID: String
        let customPath: String
        let installedAt: Date

        var customURL: URL {
            URL(fileURLWithPath: customPath)
        }

        var profileTitle: String {
            ClientProfileRegistry.managedHookProfile(id: profileID)?.title ?? profileID
        }
    }

    static func customInstallations() -> [CustomHookInstallation] {
        guard let data = UserDefaults.standard.data(forKey: customInstallationsDefaultsKey),
              let installations = try? JSONDecoder().decode([CustomHookInstallation].self, from: data) else {
            return []
        }
        return installations
    }

    static func installCustom(profileID: String, directoryPath: String) {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: profileID) else {
            return
        }

        let directoryURL = URL(fileURLWithPath: directoryPath)
        let url = customInstallationURL(for: profile, baseDirectory: directoryURL)
        let activationConfigURL = customActivationConfigurationURL(for: profile, baseDirectory: directoryURL)

        installBridgeLauncherIfNeeded()
        switch profile.installationKind {
        case .jsonHooks:
            updateHooks(at: url, profile: profile)
        case .pluginFile:
            writeManagedPlugin(at: url, profile: profile)
            setManagedPluginEnabled(true, for: profile, customConfigURL: activationConfigURL, pluginURL: url)
        case .pluginDirectory:
            writeManagedPluginDirectory(at: url, profile: profile)
        case .hookDirectory:
            writeManagedHookDirectory(at: url, profile: profile)
            setInternalHookEnabled(true, for: profile, customConfigURL: activationConfigURL)
        }

        let installation = CustomHookInstallation(
            id: UUID().uuidString,
            profileID: profileID,
            customPath: url.path,
            installedAt: Date()
        )
        var existing = customInstallations()
        existing.append(installation)
        persistCustomInstallations(existing)
    }

    static func uninstallCustom(id: String) {
        var installations = customInstallations()
        guard let index = installations.firstIndex(where: { $0.id == id }) else {
            return
        }

        let installation = installations[index]
        let url = installation.customURL

        if let profile = ClientProfileRegistry.managedHookProfile(id: installation.profileID) {
            let activationConfigURL = customActivationConfigurationURL(for: profile, installedURL: url)
            switch profile.installationKind {
            case .jsonHooks:
                removeManagedHooks(at: url)
            case .pluginFile:
                removeManagedPlugin(at: url, profile: profile)
                setManagedPluginEnabled(false, for: profile, customConfigURL: activationConfigURL, pluginURL: url)
            case .pluginDirectory:
                removeManagedPluginDirectory(at: url, profile: profile)
            case .hookDirectory:
                removeManagedHookDirectory(at: url, profile: profile)
                setInternalHookEnabled(false, for: profile, customConfigURL: activationConfigURL)
            }
        }

        installations.remove(at: index)
        persistCustomInstallations(installations)
    }

    static func isCustomInstalled(_ installation: CustomHookInstallation) -> Bool {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: installation.profileID) else {
            return false
        }
        let url = installation.customURL
        switch profile.installationKind {
        case .jsonHooks:
            return containsManagedHooks(at: url)
        case .pluginFile:
            return containsManagedPlugin(at: url, profile: profile)
        case .pluginDirectory:
            return containsManagedPluginDirectory(at: url, profile: profile)
        case .hookDirectory:
            let activationConfigURL = customActivationConfigurationURL(for: profile, installedURL: url)
            return containsManagedHookDirectory(at: url, profile: profile)
                && isInternalHookEnabled(at: activationConfigURL, for: profile)
        }
    }

    private static func persistCustomInstallations(_ installations: [CustomHookInstallation]) {
        guard let data = try? JSONEncoder().encode(installations) else {
            return
        }
        UserDefaults.standard.set(data, forKey: customInstallationsDefaultsKey)
    }

    // MARK: - JSON Utilities

    nonisolated static func remoteBridgeBinaryURL() -> URL? {
        let bundledBridgeURL = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(bridgeBinaryName)
        if let bundledBridgeURL,
           FileManager.default.isReadableFile(atPath: bundledBridgeURL.path) {
            return bundledBridgeURL
        }

        let fallbackURL = URL(fileURLWithPath: "/Users/wudanwu/Island/Prototype/.build/debug/\(bridgeBinaryName)")
        if FileManager.default.isReadableFile(atPath: fallbackURL.path) {
            return fallbackURL
        }

        return nil
    }

    nonisolated static func managedBridgeCommand(
        source: String,
        extraArguments: [String],
        launcherPath: String,
        socketPath: String?
    ) -> String {
        var components: [String] = []
        if let socketPath, !socketPath.isEmpty {
            components.append("ISLAND_SOCKET_PATH=\(shellQuoted(socketPath))")
        }
        components.append(shellQuoted(launcherPath))
        components.append("--source")
        components.append(source)
        components.append(contentsOf: extraArguments.map(shellQuoted))
        return components.joined(separator: " ")
    }

    nonisolated static func updatedInternalHookConfigurationData(
        existingData: Data?,
        entryName: String,
        installing: Bool
    ) -> Data {
        var json: [String: Any] = [:]
        if let existingData,
           let existing = HookConfigParser.parseJSONObject(from: existingData) {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var internalHooks = hooks["internal"] as? [String: Any] ?? [:]
        var entries = internalHooks["entries"] as? [String: Any] ?? [:]
        var entry = entries[entryName] as? [String: Any] ?? [:]

        entry["enabled"] = installing
        entries[entryName] = entry

        if installing {
            internalHooks["enabled"] = true
        }

        internalHooks["entries"] = entries
        hooks["internal"] = internalHooks
        json["hooks"] = hooks

        return (try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
    }

    nonisolated static func isInternalHookEnabled(
        existingData: Data?,
        entryName: String
    ) -> Bool {
        guard let existingData,
              let json = HookConfigParser.parseJSONObject(from: existingData),
              let hooks = json["hooks"] as? [String: Any],
              let internalHooks = hooks["internal"] as? [String: Any],
              let entries = internalHooks["entries"] as? [String: Any],
              let entry = entries[entryName] as? [String: Any],
              let enabled = entry["enabled"] as? Bool else {
            return false
        }

        return enabled
    }

    nonisolated static func updatedConfigurationData(
        existingData: Data?,
        profile: ManagedHookClientProfile,
        customCommand: String,
        installing: Bool,
        removingCommandPrefixes: [String] = [],
        pluginURL: URL? = nil
    ) -> Data {
        var json: [String: Any] = [:]
        if let existingData,
           let existing = HookConfigParser.parseJSONObject(from: existingData) {
            json = existing
        }

        switch profile.installationKind {
        case .jsonHooks:
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            if installing {
                for event in profile.events {
                    let existingEvent = sanitizedHookEntries(
                        hooks[event.name] as? [[String: Any]],
                        removingCommandPrefixes: removingCommandPrefixes
                    )
                    hooks[event.name] = normalizedHookEntries(
                        existingEvent,
                        preferred: makeHookEntries(command: customCommand, event: event)
                    )
                }
            } else {
                for (event, value) in hooks {
                    guard var entries = value as? [[String: Any]] else { continue }
                    entries.removeAll { entry in
                        isIslandManagedHookEntry(entry)
                    }
                    if entries.isEmpty {
                        hooks.removeValue(forKey: event)
                    } else {
                        hooks[event] = entries
                    }
                }
            }

            if hooks.isEmpty {
                json.removeValue(forKey: "hooks")
            } else {
                json["hooks"] = hooks
            }

        case .pluginFile:
            let targetPluginURL = pluginURL ?? profile.primaryConfigurationURL
            let pluginSpecifier = targetPluginURL.absoluteURL.absoluteString
            let pluginPath = targetPluginURL.path
            let existingPlugins = json["plugin"] as? [Any] ?? []
            let filteredPlugins = existingPlugins.filter { entry in
                !pluginEntry(entry, matches: pluginSpecifier, pluginPath: pluginPath)
            }

            if installing {
                json["plugin"] = filteredPlugins + [pluginSpecifier]
            } else if filteredPlugins.isEmpty {
                json.removeValue(forKey: "plugin")
            } else {
                json["plugin"] = filteredPlugins
            }
        case .pluginDirectory, .hookDirectory:
            break
        }

        let data = (try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
        return data
    }

    private static func sanitizedHookEntries(
        _ entries: [[String: Any]]?,
        removingCommandPrefixes: [String]
    ) -> [[String: Any]]? {
        guard !removingCommandPrefixes.isEmpty else { return entries }
        return entries?.filter { entry in
            !entryContainsCommand(entry, withPrefixes: removingCommandPrefixes)
        }
    }

    private static func entryContainsCommand(
        _ entry: [String: Any],
        withPrefixes prefixes: [String]
    ) -> Bool {
        if let command = hookCommandString(from: entry) {
            return prefixes.contains { command.hasPrefix($0) }
        }

        if let nestedHooks = entry["hooks"] as? [[String: Any]] {
            return nestedHooks.contains { hook in
                guard let command = hookCommandString(from: hook) else { return false }
                return prefixes.contains { command.hasPrefix($0) }
            }
        }

        return false
    }

    private static func writeJSONObject(_ json: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url)
        }
    }

    private static func writeData(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func customInstallationURL(for profile: ManagedHookClientProfile, baseDirectory: URL) -> URL {
        switch profile.installationKind {
        case .jsonHooks, .pluginFile:
            return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent)
        case .pluginDirectory:
            if baseDirectory.lastPathComponent == ".hermes" {
                return baseDirectory
                    .appendingPathComponent("plugins", isDirectory: true)
                    .appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent, isDirectory: true)
            }
            if baseDirectory.lastPathComponent == "plugins" {
                return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent, isDirectory: true)
            }
            return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent, isDirectory: true)
        case .hookDirectory:
            let selectedName = baseDirectory.lastPathComponent
            if selectedName == ".openclaw" || FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent("openclaw.json").path) {
                return baseDirectory
                    .appendingPathComponent("hooks", isDirectory: true)
                    .appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent, isDirectory: true)
            }
            if selectedName == "hooks" {
                return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent, isDirectory: true)
            }
            return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent, isDirectory: true)
        }
    }

    private static func customActivationConfigurationURL(for profile: ManagedHookClientProfile, baseDirectory: URL) -> URL? {
        switch profile.installationKind {
        case .pluginFile:
            if baseDirectory.lastPathComponent == "plugins" {
                return baseDirectory.deletingLastPathComponent().appendingPathComponent("config.json")
            }
            return baseDirectory.appendingPathComponent("config.json")
        case .jsonHooks, .pluginDirectory:
            return nil
        case .hookDirectory:
            break
        }

        let selectedName = baseDirectory.lastPathComponent
        if selectedName == ".openclaw" || FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent("openclaw.json").path) {
            return baseDirectory.appendingPathComponent("openclaw.json")
        }
        if selectedName == "hooks" {
            return baseDirectory.deletingLastPathComponent().appendingPathComponent("openclaw.json")
        }
        return profile.activationConfigurationURL
    }

    private static func customActivationConfigurationURL(for profile: ManagedHookClientProfile, installedURL: URL) -> URL? {
        switch profile.installationKind {
        case .pluginFile:
            return installedURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config.json")
        case .jsonHooks, .pluginDirectory:
            return nil
        case .hookDirectory:
            break
        }
        let parent = installedURL.deletingLastPathComponent()
        if parent.lastPathComponent == "hooks" {
            return parent.deletingLastPathComponent().appendingPathComponent("openclaw.json")
        }
        return profile.activationConfigurationURL
    }

    private static func isInternalHookEnabled(at url: URL?, for profile: ManagedHookClientProfile) -> Bool {
        guard let url,
              let entryName = profile.activationEntryName,
              let data = try? Data(contentsOf: url) else {
            return false
        }
        return isInternalHookEnabled(existingData: data, entryName: entryName)
    }

    private nonisolated static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    nonisolated static func isManagedPluginEnabled(existingData: Data?, pluginURL: URL) -> Bool {
        guard let existingData,
              let json = HookConfigParser.parseJSONObject(from: existingData),
              let plugins = json["plugin"] as? [Any] else {
            return false
        }

        let pluginSpecifier = pluginURL.absoluteURL.absoluteString
        let pluginPath = pluginURL.path
        return plugins.contains { pluginEntry($0, matches: pluginSpecifier, pluginPath: pluginPath) }
    }

    private static func pluginEntry(_ entry: Any, matches pluginSpecifier: String, pluginPath: String) -> Bool {
        if let string = entry as? String {
            return normalizedPluginLocation(string) == normalizedPluginLocation(pluginSpecifier)
                || normalizedPluginLocation(string) == normalizedPluginLocation(pluginPath)
        }

        if let pair = entry as? [Any],
           let string = pair.first as? String {
            return normalizedPluginLocation(string) == normalizedPluginLocation(pluginSpecifier)
                || normalizedPluginLocation(string) == normalizedPluginLocation(pluginPath)
        }

        return false
    }

    private static func normalizedPluginLocation(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
