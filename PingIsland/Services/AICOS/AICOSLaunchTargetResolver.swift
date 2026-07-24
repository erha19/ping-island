import Foundation

enum AICOSLaunchTargetResolver {
    static func installedProfiles(
        from profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        isInstalled: (ManagedHookClientProfile) -> Bool
    ) -> [ManagedHookClientProfile] {
        profiles.filter(isInstalled)
    }

    static func resolve(
        storedProfileID: String?,
        installed: [ManagedHookClientProfile]
    ) -> ManagedHookClientProfile? {
        if let storedProfileID,
           let match = installed.first(where: { $0.id == storedProfileID }) {
            return match
        }
        if let codex = installed.first(where: { $0.id == "codex-hooks" }) {
            return codex
        }
        return installed.first
    }

    static func loadStoredProfileID(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: AICOSMissionConstants.launchTargetProfileIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func setStoredProfileID(_ profileID: String?, defaults: UserDefaults = .standard) {
        let trimmed = profileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: AICOSMissionConstants.launchTargetProfileIDDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: AICOSMissionConstants.launchTargetProfileIDDefaultsKey)
        }
    }

    static func resolvedProfile(
        defaults: UserDefaults = .standard,
        from profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        isInstalled: (ManagedHookClientProfile) -> Bool = { HookInstaller.isInstalled($0) }
    ) -> ManagedHookClientProfile? {
        resolve(
            storedProfileID: loadStoredProfileID(defaults: defaults),
            installed: installedProfiles(from: profiles, isInstalled: isInstalled)
        )
    }
}
