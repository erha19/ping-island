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

    private static func managedPluginSource(for profile: ManagedHookClientProfile) -> String {
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
            return value.trim().length > 0 ? value : undefined;
          }
          try {
            return JSON.stringify(value);
          } catch {
            return undefined;
          }
        }

        function statusFor(type) {
          switch (type) {
            case "session.idle":
              return "waitingForInput";
            case "session.active":
              return "thinking";
            case "tool.execute.before":
              return "runningTool";
            case "permission.asked":
              return "waitingForApproval";
            case "permission.replied":
            case "tool.execute.after":
            case "message.updated":
            case "session.updated":
              return "active";
            default:
              return "active";
          }
        }

        function buildPayload(event) {
          const type = event?.type;
          if (typeof type !== "string" || type.length === 0) {
            return undefined;
          }

          const cwd = firstDefined(event, [
            ["session", "path", "cwd"],
            ["session", "cwd"],
            ["cwd"],
            ["directory"],
            ["worktree", "path"],
            ["path", "cwd"]
          ]);

          const sessionId = firstDefined(event, [
            ["session", "id"],
            ["session", "sessionID"],
            ["session", "sessionId"],
            ["sessionID"],
            ["sessionId"],
            ["threadID"],
            ["threadId"]
          ]);

          const toolName = firstDefined(event, [
            ["input", "tool"],
            ["tool", "name"],
            ["toolName"],
            ["permission", "tool"],
            ["details", "tool"]
          ]) ?? firstString(event, ["tool", "toolName", "name"]);

          const toolInput = firstDefined(event, [
            ["input", "input"],
            ["input", "args"],
            ["tool", "input"],
            ["toolInput"],
            ["details", "input"]
          ]) ?? firstObject(event, ["input", "args", "toolInput", "parameters"]);

          const command = firstDefined(event, [
            ["input", "input", "command"],
            ["input", "args", "command"],
            ["command"],
            ["details", "command"]
          ]) ?? firstString(event, ["command"]);

          const message = firstDefined(event, [
            ["message"],
            ["text"],
            ["output", "text"],
            ["output", "message"],
            ["permission", "message"],
            ["details", "message"]
          ]) ?? firstString(event, ["message", "text", "summary"]);

          const reason = firstDefined(event, [
            ["permission", "reason"],
            ["details", "reason"],
            ["reason"]
          ]) ?? firstString(event, ["reason"]);

          const payload = {
            event: type,
            session_id: typeof sessionId === "string" ? sessionId : stableString(sessionId),
            cwd: typeof cwd === "string" ? cwd : stableString(cwd),
            status: statusFor(type),
            tool_name: typeof toolName === "string" ? toolName : stableString(toolName),
            tool_input: isObject(toolInput) || Array.isArray(toolInput) ? toolInput : undefined,
            command: typeof command === "string" ? command : stableString(command),
            message: typeof message === "string" ? message : stableString(message),
            reason: typeof reason === "string" ? reason : stableString(reason),
            client_kind: "opencode",
            client_name: "OpenCode",
            client_origin: "cli",
            client_originator: "OpenCode",
            thread_source: "opencode-plugin"
          };

          return Object.fromEntries(
            Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== "")
          );
        }

        async function forwardEvent(event) {
          const payload = buildPayload(event);
          if (!payload) return;

          try {
            const subprocess = Bun.spawn(BRIDGE_ARGS, {
              stdin: new Response(JSON.stringify(payload)),
              stdout: "ignore",
              stderr: "ignore",
              env: globalThis.process?.env
            });
            await subprocess.exited;
          } catch {
            // OpenCode hooks should never fail because Island is unavailable.
          }
        }

        export default {
          name: "Ping Island",
          description: "Forward OpenCode hook events to Ping Island.",
          event: async ({ event }) => {
            await forwardEvent(event);
          }
        };
        """
    }

    private static func managedHookDirectoryFiles(for profile: ManagedHookClientProfile) -> [String: String] {
        guard profile.id == "openclaw-hooks" else {
            return [:]
        }

        let argsData = (try? JSONSerialization.data(withJSONObject: bridgeCommandArguments(for: profile), options: []))
            ?? Data("[]".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        let eventList = profile.events.map(\.name)
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
          const sessionId = stableString(event?.sessionKey);
          if (!sessionId) return undefined;

          const payload = {
            event: `${event?.type ?? "unknown"}:${event?.action ?? "unknown"}`,
            session_id: sessionId,
            cwd: firstDefined(
              event?.context?.workspaceDir,
              event?.context?.sessionEntry?.workspaceDir,
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

          return Object.fromEntries(
            Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== "")
          );
        }

        async function forwardViaNode(payload) {
          const { spawn } = await import("node:child_process");
          const child = spawn(BRIDGE_ARGS[0], BRIDGE_ARGS.slice(1), {
            stdio: ["pipe", "ignore", "ignore"],
            env: process.env
          });
          child.on("error", () => {});
          child.stdin.write(JSON.stringify(payload));
          child.stdin.end();
        }

        const handler = async (event) => {
          const payload = buildPayload(event);
          if (!payload) return;

          try {
            if (typeof Bun !== "undefined" && typeof Bun.spawn === "function") {
              const subprocess = Bun.spawn(BRIDGE_ARGS, {
                stdin: new Response(JSON.stringify(payload)),
                stdout: "ignore",
                stderr: "ignore",
                env: globalThis.process?.env
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
        removingCommandPrefixes: [String] = []
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
            break
        case .hookDirectory:
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
        guard profile.installationKind == .hookDirectory else {
            return nil
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
        guard profile.installationKind == .hookDirectory else {
            return nil
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
}
