//
//  HookInstaller.swift
//  PingIsland
//
//  Installs and manages hook integrations for supported clients.
//

import Foundation

struct HookInstaller {
    private static let preferredTargetsDefaultsKey = "HookInstaller.preferredTargets.v1"
    private static let qoderMigrationDefaultsKey = "HookInstaller.preferredTargets.qoder-default.v1"
    private static let qoderWorkMigrationDefaultsKey = "HookInstaller.preferredTargets.qoderwork-default.v1"
    private static let installedVersionDefaultsKey = "HookInstaller.installedVersion.v1"
    private static let firstLaunchDefaultsKey = "HookInstaller.isFirstLaunch.v1"

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
        profile.configurationURLs.contains { containsManagedHooks(at: $0) }
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

        guard canManage(profile) else {
            return
        }

        if profile.installsClaudePythonScript {
            installClaudeScriptIfNeeded()
        }

        installBridgeLauncherIfNeeded()
        for url in installationTargets(for: profile) {
            updateHooks(at: url, profile: profile)
        }
    }

    private static func uninstall(_ profile: ManagedHookClientProfile, persistPreference: Bool) {
        if persistPreference {
            var targets = preferredTargets()
            targets.remove(profile.id)
            persistPreferredTargets(targets)
        }

        if profile.installsClaudePythonScript {
            try? FileManager.default.removeItem(at: claudePythonScriptURL())
        }

        for url in profile.configurationURLs {
            removeManagedHooks(at: url)
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

    private static func installClaudeScriptIfNeeded() {
        let hooksDir = claudeHooksDirectoryURL()
        let pythonScript = claudePythonScriptURL()

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "island-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }
    }

    private static func installationTargets(for profile: ManagedHookClientProfile) -> [URL] {
        let existingTargets = profile.configurationURLs.filter { url in
            let fileManager = FileManager.default
            return fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: url.deletingLastPathComponent().path)
        }

        return existingTargets.isEmpty ? [profile.primaryConfigurationURL] : existingTargets
    }

    private static func claudeHooksDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("hooks")
    }

    private static func claudePythonScriptURL() -> URL {
        claudeHooksDirectoryURL().appendingPathComponent("island-state.py")
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
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return isIslandManagedHookCommand(cmd)
                        }
                    }
                    return false
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
        let launcherURL = islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("island-bridge")

        guard !FileManager.default.fileExists(atPath: launcherURL.path) else {
            return
        }

        try? FileManager.default.createDirectory(
            at: launcherURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let bundleBridge = (Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("IslandBridge")
            .path) ?? ""

        let script = """
        #!/bin/zsh
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        candidates=(
          "$SCRIPT_DIR/IslandBridge"
          "\(bundleBridge)"
        )

        for candidate in "${candidates[@]}"; do
          if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            exec "$candidate" "$@"
          fi
        done

        echo "IslandBridge binary not found" >&2
        exit 127
        """

        try? Data(script.utf8).write(to: launcherURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherURL.path
        )
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    private static func normalizedHookEntries(
        _ existingEntries: [[String: Any]]?,
        preferred: [[String: Any]]
    ) -> [[String: Any]] {
        let preservedEntries = (existingEntries ?? []).filter { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                return true
            }

            return !entryHooks.contains { hook in
                let command = hook["command"] as? String ?? ""
                return isIslandManagedHookCommand(command)
            }
        }

        return preservedEntries + preferred
    }

    private static func updateHooks(at url: URL, profile: ManagedHookClientProfile) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        // Add version field for GitHub Copilot hooks
        if profile.brand == .copilot {
            if json["version"] == nil {
                json["version"] = 1
            }
        }

        let command: String
        if profile.installsClaudePythonScript {
            let python = detectPython()
            command = "\(python) ~/.claude/hooks/island-state.py"
        } else {
            command = bridgeCommand(source: profile.bridgeSource, extraArguments: profile.bridgeExtraArguments)
        }

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

    private static func islandSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".island", isDirectory: true)
    }

    private static func bridgeCommand(source: String, extraArguments: [String] = []) -> String {
        let base = islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("island-bridge")
            .path + " --source \(source)"
        guard !extraArguments.isEmpty else { return base }
        return ([base] + extraArguments).joined(separator: " ")
    }

    private static func containsManagedHooks(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               isIslandManagedHookCommand(cmd) {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    private static func isIslandManagedHookCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("island-state.py")
            || normalized.contains("/.island/bin/island-bridge")
            || normalized.contains("/.vibe-island/bin/vibe-island-bridge")
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
}
