//
//  LocalSkillModels.swift
//  PingIsland
//
//  Domain models for the local skill manager and central route registry.
//

import Foundation

struct LocalSkill: Identifiable, Hashable, Sendable {
    /// Standardized absolute directory path (also the registry key).
    var id: String
    var name: String
    var description: String?
    var directoryPath: String
    var skillMarkdownPath: String
    var sourceLabel: String

    var folderName: String {
        URL(fileURLWithPath: directoryPath).lastPathComponent
    }
}

struct SkillRouteOverride: Codable, Equatable, Sendable {
    var launch_profile_id: String?
    var linked_profile_ids: [String]

    init(launch_profile_id: String? = nil, linked_profile_ids: [String] = []) {
        self.launch_profile_id = launch_profile_id
        self.linked_profile_ids = linked_profile_ids
    }
}

struct SkillRouteRegistrySnapshot: Codable, Equatable, Sendable {
    var global_launch_profile_id: String?
    var vault_root_path: String?
    var manual_roots: [String]
    var routes: [String: SkillRouteOverride]

    init(
        global_launch_profile_id: String? = nil,
        vault_root_path: String? = nil,
        manual_roots: [String] = [],
        routes: [String: SkillRouteOverride] = [:]
    ) {
        self.global_launch_profile_id = global_launch_profile_id
        self.vault_root_path = vault_root_path
        self.manual_roots = manual_roots
        self.routes = routes
    }

    static let empty = SkillRouteRegistrySnapshot()
}

enum SkillManagerConstants {
    static let registryDefaultsKey = "SkillManager.registry.v1"
    static let usageDefaultsKey = "SkillManager.usage.v1"
    /// Depth limit when recursively scanning a skill root for SKILL.md.
    static let maxScanDepth = 4

    nonisolated static var defaultVaultRootPath: String {
        NSHomeDirectory() + "/.agents/skills"
    }
}

struct SkillUsageSnapshot: Codable, Equatable, Sendable {
    var use_counts: [String: Int]

    static let empty = SkillUsageSnapshot(use_counts: [:])
}

enum SkillLinkStatus: Equatable, Sendable {
    case linked
    case missing
    case conflict(existingPath: String)
    case skillsDirectoryMissing
}

enum SkillConsolidateAction: Equatable, Sendable {
    case moveThenRelink
    /// Vault missing; only external symlinks exist — create vault symlink to the
    /// preferred external target, then point agent locations at the vault.
    case adoptExternalThenRelink(externalTarget: String)
    case relinkOnly
    case skipAlreadyLinked
    case conflict(reason: String)
}

struct SkillConsolidateGroupPlan: Equatable, Sendable, Identifiable {
    var id: String { folder_name }
    var folder_name: String
    var canonical_destination: String
    var winner_path: String?
    var relink_paths: [String]
    var action: SkillConsolidateAction
}

struct SkillConsolidatePlan: Equatable, Sendable {
    var vault_root: String
    var groups: [SkillConsolidateGroupPlan]

    var moveCount: Int {
        groups.filter { $0.action == .moveThenRelink }.count
    }

    var adoptCount: Int {
        groups.filter {
            if case .adoptExternalThenRelink = $0.action { return true }
            return false
        }.count
    }

    var relinkCount: Int {
        groups.reduce(0) { partial, group in
            switch group.action {
            case .moveThenRelink:
                return partial + group.relink_paths.count + 1
            case .adoptExternalThenRelink:
                return partial + group.relink_paths.count
            case .relinkOnly:
                return partial + group.relink_paths.count
            default:
                return partial
            }
        }
    }

    var skipCount: Int {
        groups.filter {
            if case .skipAlreadyLinked = $0.action { return true }
            return false
        }.count
    }

    var conflictCount: Int {
        groups.filter {
            if case .conflict = $0.action { return true }
            return false
        }.count
    }

    var workCount: Int {
        moveCount + adoptCount + groups.filter {
            if case .relinkOnly = $0.action { return !$0.relink_paths.isEmpty }
            return false
        }.count
    }
}

struct SkillConsolidateResult: Equatable, Sendable {
    var moved: [String]
    var adopted: [String]
    var relinked: [String]
    var skipped: [String]
    var conflicts: [String]
}
