//
//  SkillUsageStore.swift
//  PingIsland
//
//  Persists per-skill launch usage counts keyed by folder_name.
//

import Foundation

enum SkillUsageStore {
    nonisolated static func load(defaults: UserDefaults = .standard) -> SkillUsageSnapshot {
        guard let data = defaults.data(forKey: SkillManagerConstants.usageDefaultsKey),
              let decoded = try? JSONDecoder().decode(SkillUsageSnapshot.self, from: data)
        else {
            return .empty
        }
        return decoded
    }

    nonisolated static func save(_ snapshot: SkillUsageSnapshot, defaults: UserDefaults = .standard) {
        var normalized = SkillUsageSnapshot(use_counts: [:])
        for (key, value) in snapshot.use_counts {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, value > 0 else { continue }
            normalized.use_counts[trimmed] = value
        }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: SkillManagerConstants.usageDefaultsKey)
        }
    }

    nonisolated static func useCount(
        folderName: String,
        defaults: UserDefaults = .standard
    ) -> Int {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(0, load(defaults: defaults).use_counts[trimmed] ?? 0)
    }

    @discardableResult
    nonisolated static func recordUse(
        folderName: String,
        defaults: UserDefaults = .standard
    ) -> Int {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var snapshot = load(defaults: defaults)
        let next = max(0, snapshot.use_counts[trimmed] ?? 0) + 1
        snapshot.use_counts[trimmed] = next
        save(snapshot, defaults: defaults)
        return next
    }
}
