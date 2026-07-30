//
//  SkillRemoteCatalog.swift
//  PingIsland
//
//  Built-in allowlisted remote skill repositories.
//

import Foundation

struct SkillRemoteCatalogDefinition: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var owner: String
    var repo: String
    var default_ref: String
    /// Path prefixes that may contain skill directories (e.g. "skills").
    var skills_roots: [String]

    var repository_slug: String { "\(owner)/\(repo)" }
}

struct SkillRemoteSkillSummary: Identifiable, Hashable, Sendable {
    var id: String { "\(catalog_id):\(remote_path)" }
    var catalog_id: String
    var folder_name: String
    /// Repo-relative directory path containing SKILL.md (e.g. "skills/pdf").
    var remote_path: String
    var name: String?
    var description: String?
}

enum SkillRemoteCatalog {
    static let builtIn: [SkillRemoteCatalogDefinition] = [
        SkillRemoteCatalogDefinition(
            id: "anthropic-skills",
            title: "Anthropic Skills",
            owner: "anthropics",
            repo: "skills",
            default_ref: "main",
            skills_roots: ["skills"]
        ),
    ]

    nonisolated static func definition(id: String) -> SkillRemoteCatalogDefinition? {
        builtIn.first { $0.id == id }
    }
}
