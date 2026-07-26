//
//  AICOSDecisionSkillCatalog.swift
//  PingIsland
//
//  Resolves the decision skill root used by the Investment Decision mission entry.
//

import Foundation

enum AICOSDecisionSkillCatalog {
    static let skillRelativePath = "SKILL.md"
    static let investmentAdapterRelativePath = "references/investment-adapter.md"

    static func resolvedDecisionSkillRoot(
        override: String? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> URL {
        let stored = override
            ?? defaults.string(forKey: AICOSMissionConstants.decisionSkillRootDefaultsKey)
            ?? AICOSMissionConstants.defaultDecisionSkillRootPath
        return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func setDecisionSkillRootPath(_ path: String, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: AICOSMissionConstants.decisionSkillRootDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: AICOSMissionConstants.decisionSkillRootDefaultsKey)
        }
    }

    static func decisionSkillExists(
        override: String? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let root = resolvedDecisionSkillRoot(override: override, fileManager: fileManager, defaults: defaults)
        let skill = root.appendingPathComponent(skillRelativePath)
        let adapter = root.appendingPathComponent(investmentAdapterRelativePath)
        return fileManager.fileExists(atPath: skill.path)
            && fileManager.fileExists(atPath: adapter.path)
    }

    static func requiredReadingPaths(
        override: String? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> [String] {
        let root = resolvedDecisionSkillRoot(override: override, fileManager: fileManager, defaults: defaults)
        return [
            root.appendingPathComponent(skillRelativePath).path,
            root.appendingPathComponent(investmentAdapterRelativePath).path
        ]
    }
}
