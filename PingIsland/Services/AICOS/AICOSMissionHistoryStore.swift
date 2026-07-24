//
//  AICOSMissionHistoryStore.swift
//  PingIsland
//
//  Persists the most recent AI-COS mission draft for Island UI.
//

import Foundation

enum AICOSMissionHistoryStore {
    static func saveRecent(_ draft: AICOSMissionDraft, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: AICOSMissionConstants.recentMissionDefaultsKey)
    }

    static func loadRecent(defaults: UserDefaults = .standard) -> AICOSMissionDraft? {
        guard let data = defaults.data(forKey: AICOSMissionConstants.recentMissionDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AICOSMissionDraft.self, from: data)
    }

    static func clearRecent(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AICOSMissionConstants.recentMissionDefaultsKey)
    }
}
