import Foundation

enum HookHealthStatus: String, Codable, Equatable, Sendable {
    case installed
    case missing
    case stale
    case conflict

    var title: String {
        switch self {
        case .installed: return "installed"
        case .missing: return "missing"
        case .stale: return "stale"
        case .conflict: return "conflict"
        }
    }
}

struct HookHealthSnapshot: Identifiable, Codable, Equatable, Sendable {
    let profileID: String
    let title: String
    let status: HookHealthStatus
    let detail: String
    let configurationPaths: [String]
    let installed: Bool
    let eventCount: Int
    let checkedAt: Date

    var id: String { profileID }
}

enum HookHealthCenter {
    static func snapshots(
        profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [HookHealthSnapshot] {
        profiles.map { snapshot(for: $0, fileManager: fileManager, now: now) }
    }

    static func snapshot(
        for profile: ManagedHookClientProfile,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> HookHealthSnapshot {
        let installed = HookInstaller.isInstalled(profile)
        let paths = profile.configurationURLs.map(\.path)
        let existingURLs = profile.configurationURLs.filter { fileManager.fileExists(atPath: $0.path) }
        let contents = existingURLs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let hasIslandSignature = contents.contains { content in
            content.localizedCaseInsensitiveContains("ping-island-bridge")
                || content.localizedCaseInsensitiveContains("island-bridge")
                || content.localizedCaseInsensitiveContains("Ping Island managed integration")
        }
        let hasLegacySignature = contents.contains { content in
            content.localizedCaseInsensitiveContains("island-bridge")
                || content.localizedCaseInsensitiveContains("IslandBridge")
        }

        let status: HookHealthStatus
        let detail: String
        if installed && hasLegacySignature {
            status = .stale
            detail = "Detected an Island hook, but it still references legacy bridge naming."
        } else if installed {
            status = .installed
            detail = "Managed hook is present and matches the current profile."
        } else if hasIslandSignature {
            status = .conflict
            detail = "Island hook material is present, but the current profile cannot validate it."
        } else if existingURLs.isEmpty {
            status = .missing
            detail = "No configuration file exists yet at the expected path."
        } else {
            status = .missing
            detail = "Configuration exists, but no Island managed hook entry was found."
        }

        return HookHealthSnapshot(
            profileID: profile.id,
            title: profile.title,
            status: status,
            detail: detail,
            configurationPaths: paths,
            installed: installed,
            eventCount: profile.events.count,
            checkedAt: now
        )
    }

    static func diagnosticsReport(for snapshots: [HookHealthSnapshot]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
