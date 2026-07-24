//
//  AICOSProtocolCatalog.swift
//  PingIsland
//
//  Default AI-COS skill mapping and protocol root resolution.
//

import Foundation

enum AICOSProtocolCatalog {
    static let allSkills: [AICOSSkillRef] = [
        AICOSSkillRef(
            id: "readme",
            title: "AI-COS README",
            relativePath: "README.md",
            levels: [.l1, .l2, .l3]
        ),
        AICOSSkillRef(
            id: "protocol",
            title: "Execution Protocol",
            relativePath: "PROTOCOL.md",
            levels: [.l1, .l2, .l3]
        ),
        AICOSSkillRef(
            id: "constitution",
            title: "Constitution",
            relativePath: "constitution.md",
            levels: [.l2, .l3]
        ),
        AICOSSkillRef(
            id: "example-l1",
            title: "L1 example",
            relativePath: "examples/l1-simple-task.md",
            levels: [.l1]
        ),
        AICOSSkillRef(
            id: "example-l2",
            title: "L2 example",
            relativePath: "examples/l2-standard-task.md",
            levels: [.l2]
        ),
        AICOSSkillRef(
            id: "schema-goal",
            title: "Goal schema",
            relativePath: "schemas/goal.md",
            levels: [.l3]
        ),
        AICOSSkillRef(
            id: "schema-state",
            title: "State schema",
            relativePath: "schemas/state.md",
            levels: [.l3]
        ),
        AICOSSkillRef(
            id: "schema-handoff",
            title: "Handoff schema",
            relativePath: "schemas/handoff.md",
            levels: [.l3]
        ),
        AICOSSkillRef(
            id: "template-goal",
            title: "Goal template",
            relativePath: "templates/GOAL.template.md",
            levels: [.l3]
        ),
        AICOSSkillRef(
            id: "template-state",
            title: "State template",
            relativePath: "templates/STATE.template.md",
            levels: [.l3]
        ),
        AICOSSkillRef(
            id: "example-l3-goal",
            title: "L3 Goal example",
            relativePath: "examples/l3-complex-task/GOAL.md",
            levels: [.l3]
        ),
        AICOSSkillRef(
            id: "example-l3-state",
            title: "L3 State example",
            relativePath: "examples/l3-complex-task/STATE.md",
            levels: [.l3]
        )
    ]

    static func skills(for level: AICOSExecutionLevel) -> [AICOSSkillRef] {
        allSkills.filter { $0.levels.contains(level) }
    }

    static func defaultSelectedSkillIDs(for level: AICOSExecutionLevel) -> [String] {
        skills(for: level).map(\.id)
    }

    static func skill(id: String) -> AICOSSkillRef? {
        allSkills.first { $0.id == id }
    }

    static func resolvedProtocolRoot(
        override: String? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> URL {
        let stored = override
            ?? defaults.string(forKey: AICOSMissionConstants.protocolRootDefaultsKey)
            ?? AICOSMissionConstants.defaultProtocolRootPath
        let url = URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true)
        if fileManager.fileExists(atPath: url.path) {
            return url
        }
        return url
    }

    static func setProtocolRootPath(_ path: String, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: AICOSMissionConstants.protocolRootDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: AICOSMissionConstants.protocolRootDefaultsKey)
        }
    }

    static func protocolRootExists(
        override: String? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let root = resolvedProtocolRoot(override: override, fileManager: fileManager, defaults: defaults)
        return fileManager.fileExists(atPath: root.appendingPathComponent("PROTOCOL.md").path)
    }
}
