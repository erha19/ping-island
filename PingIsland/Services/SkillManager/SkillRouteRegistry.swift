//
//  SkillRouteRegistry.swift
//  PingIsland
//
//  Central persistence for skill launch routing and symlink intent.
//

import Foundation

enum SkillRouteRegistry {
    nonisolated static func load(defaults: UserDefaults = .standard) -> SkillRouteRegistrySnapshot {
        if let data = defaults.data(forKey: SkillManagerConstants.registryDefaultsKey),
           let decoded = try? JSONDecoder().decode(SkillRouteRegistrySnapshot.self, from: data) {
            return migratingLegacyLaunchTarget(decoded, defaults: defaults)
        }
        return migratingLegacyLaunchTarget(.empty, defaults: defaults)
    }

    nonisolated static func save(_ snapshot: SkillRouteRegistrySnapshot, defaults: UserDefaults = .standard) {
        var normalized = snapshot
        normalized.manual_roots = normalized.manual_roots
            .map { ($0 as NSString).standardizingPath }
            .filter { !$0.isEmpty }
        var uniqueRoots: [String] = []
        var seen = Set<String>()
        for root in normalized.manual_roots {
            if seen.insert(root).inserted {
                uniqueRoots.append(root)
            }
        }
        normalized.manual_roots = uniqueRoots

        if let vault = normalized.vault_root_path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !vault.isEmpty {
            normalized.vault_root_path = (vault as NSString).standardizingPath
        } else {
            normalized.vault_root_path = nil
        }

        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: SkillManagerConstants.registryDefaultsKey)
        }

        // Keep legacy AI-COS launch key in sync so older settings code paths stay coherent.
        AICOSLaunchTargetResolver.setStoredProfileID(
            normalized.global_launch_profile_id,
            defaults: defaults
        )
    }

    nonisolated static func resolvedVaultRootPath(
        snapshot: SkillRouteRegistrySnapshot? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        let loaded = snapshot ?? load(defaults: defaults)
        let trimmed = loaded.vault_root_path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return SkillManagerConstants.defaultVaultRootPath
        }
        return (trimmed as NSString).standardizingPath
    }

    nonisolated static func setVaultRootPath(_ path: String?, defaults: UserDefaults = .standard) {
        var snapshot = load(defaults: defaults)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        snapshot.vault_root_path = trimmed.isEmpty ? nil : trimmed
        save(snapshot, defaults: defaults)
    }

    nonisolated static func resolvedLaunchProfileID(
        for skillID: String,
        snapshot: SkillRouteRegistrySnapshot
    ) -> String? {
        if let override = snapshot.routes[skillID]?.launch_profile_id?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        let global = snapshot.global_launch_profile_id?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let global, !global.isEmpty else { return nil }
        return global
    }

    nonisolated static func resolveLaunchProfile(
        for skillID: String,
        snapshot: SkillRouteRegistrySnapshot,
        installed: [ManagedHookClientProfile]
    ) -> ManagedHookClientProfile? {
        AICOSLaunchTargetResolver.resolve(
            storedProfileID: resolvedLaunchProfileID(for: skillID, snapshot: snapshot),
            installed: installed
        )
    }

    nonisolated static func setGlobalLaunchProfileID(
        _ profileID: String?,
        defaults: UserDefaults = .standard
    ) {
        var snapshot = load(defaults: defaults)
        let trimmed = profileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        snapshot.global_launch_profile_id = trimmed.isEmpty ? nil : trimmed
        save(snapshot, defaults: defaults)
    }

    nonisolated static func setLaunchOverride(
        skillID: String,
        profileID: String?,
        defaults: UserDefaults = .standard
    ) {
        var snapshot = load(defaults: defaults)
        var route = snapshot.routes[skillID] ?? SkillRouteOverride()
        let trimmed = profileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        route.launch_profile_id = trimmed.isEmpty ? nil : trimmed
        if route.launch_profile_id == nil, route.linked_profile_ids.isEmpty {
            snapshot.routes.removeValue(forKey: skillID)
        } else {
            snapshot.routes[skillID] = route
        }
        save(snapshot, defaults: defaults)
    }

    nonisolated static func setLinkedProfileIDs(
        skillID: String,
        profileIDs: [String],
        defaults: UserDefaults = .standard
    ) {
        var snapshot = load(defaults: defaults)
        var route = snapshot.routes[skillID] ?? SkillRouteOverride()
        var unique: [String] = []
        var seen = Set<String>()
        for id in profileIDs {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            unique.append(trimmed)
        }
        route.linked_profile_ids = unique
        if route.launch_profile_id == nil, route.linked_profile_ids.isEmpty {
            snapshot.routes.removeValue(forKey: skillID)
        } else {
            snapshot.routes[skillID] = route
        }
        save(snapshot, defaults: defaults)
    }

    nonisolated static func addManualRoot(_ path: String, defaults: UserDefaults = .standard) {
        var snapshot = load(defaults: defaults)
        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty else { return }
        if !snapshot.manual_roots.contains(standardized) {
            snapshot.manual_roots.append(standardized)
            save(snapshot, defaults: defaults)
        }
    }

    nonisolated static func removeManualRoot(_ path: String, defaults: UserDefaults = .standard) {
        var snapshot = load(defaults: defaults)
        let standardized = (path as NSString).standardizingPath
        snapshot.manual_roots.removeAll { $0 == standardized || $0 == path }
        save(snapshot, defaults: defaults)
    }

    // MARK: - Private

    private nonisolated static func migratingLegacyLaunchTarget(
        _ snapshot: SkillRouteRegistrySnapshot,
        defaults: UserDefaults
    ) -> SkillRouteRegistrySnapshot {
        var copy = snapshot
        let existing = copy.global_launch_profile_id?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existing.isEmpty,
           let legacy = AICOSLaunchTargetResolver.loadStoredProfileID(defaults: defaults) {
            copy.global_launch_profile_id = legacy
        }
        return copy
    }
}
