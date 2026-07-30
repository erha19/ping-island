//
//  SkillConsolidatePlanner.swift
//  PingIsland
//
//  Builds a dry-run plan to move/dedupe skills into the central vault.
//

import Foundation

enum SkillConsolidatePlanner {
    nonisolated static func plan(
        skills: [LocalSkill],
        vaultRoot: String,
        manualRoots: [String],
        fileManager: FileManager = .default
    ) -> SkillConsolidatePlan {
        let standardizedVault = (vaultRoot as NSString).standardizingPath
        let standardizedManual = Set(manualRoots.map { ($0 as NSString).standardizingPath })

        let grouped = Dictionary(grouping: skills, by: \.folderName)
        let groups: [SkillConsolidateGroupPlan] = grouped.keys.sorted().compactMap { folderName in
            guard let members = grouped[folderName], !members.isEmpty else { return nil }
            return planGroup(
                folderName: folderName,
                members: members,
                vaultRoot: standardizedVault,
                manualRoots: standardizedManual,
                fileManager: fileManager
            )
        }

        return SkillConsolidatePlan(vault_root: standardizedVault, groups: groups)
    }

    /// Lower score = higher priority.
    nonisolated static func priorityScore(
        for skill: LocalSkill,
        manualRoots: Set<String>
    ) -> Int {
        let path = (skill.directoryPath as NSString).standardizingPath
        if manualRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return 0
        }
        if path.contains("/.claude/skills") {
            return 1
        }
        if path.contains("/.codex/skills") {
            return 2
        }
        if path.contains("/.agents/skills") {
            return 3
        }
        return 4
    }

    // MARK: - Private

    private nonisolated static func planGroup(
        folderName: String,
        members: [LocalSkill],
        vaultRoot: String,
        manualRoots: Set<String>,
        fileManager: FileManager
    ) -> SkillConsolidateGroupPlan {
        let destination = (vaultRoot as NSString).appendingPathComponent(folderName)
        let uniquePaths = orderedUniquePaths(members.map(\.directoryPath))

        let alreadyCorrect = uniquePaths.filter {
            isSymlink(at: $0, pointingTo: destination, fileManager: fileManager)
                || ($0 as NSString).standardizingPath == (destination as NSString).standardizingPath
        }
        let needingWork = uniquePaths.filter { path in
            !alreadyCorrect.contains(path)
        }

        if needingWork.isEmpty {
            return SkillConsolidateGroupPlan(
                folder_name: folderName,
                canonical_destination: destination,
                winner_path: destination,
                relink_paths: [],
                action: .skipAlreadyLinked
            )
        }

        var isDirectory: ObjCBool = false
        let destinationExists = fileManager.fileExists(atPath: destination, isDirectory: &isDirectory)

        if destinationExists {
            if isDirectory.boolValue || isSymlinkPath(destination, fileManager: fileManager) {
                return SkillConsolidateGroupPlan(
                    folder_name: folderName,
                    canonical_destination: destination,
                    winner_path: destination,
                    relink_paths: needingWork.filter {
                        ($0 as NSString).standardizingPath != (destination as NSString).standardizingPath
                    },
                    action: .relinkOnly
                )
            }
            return SkillConsolidateGroupPlan(
                folder_name: folderName,
                canonical_destination: destination,
                winner_path: nil,
                relink_paths: [],
                action: .conflict(reason: "vault destination is not a directory")
            )
        }

        let candidates = needingWork.filter { path in
            !isSymlinkPath(path, fileManager: fileManager)
        }
        if let best = candidates
            .map({ path -> (String, Int) in
                let skill = members.first(where: {
                    ($0.directoryPath as NSString).standardizingPath == (path as NSString).standardizingPath
                })
                let score = skill.map { priorityScore(for: $0, manualRoots: manualRoots) } ?? 99
                return (path, score)
            })
            .sorted(by: { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0 < rhs.0
            })
            .first {
            let winnerPath = best.0
            let relinkPaths = needingWork.filter {
                ($0 as NSString).standardizingPath != (winnerPath as NSString).standardizingPath
            }
            return SkillConsolidateGroupPlan(
                folder_name: folderName,
                canonical_destination: destination,
                winner_path: winnerPath,
                relink_paths: relinkPaths,
                action: .moveThenRelink
            )
        }

        // Only symlinks remain and vault is empty: adopt the best external target
        // into the vault as a symlink hub, then retarget agent links through vault.
        let symlinkCandidates = needingWork.compactMap { path -> (path: String, target: String, score: Int)? in
            guard isSymlinkPath(path, fileManager: fileManager),
                  let target = resolvedSymlinkTarget(at: path, fileManager: fileManager) else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: target, isDirectory: &isDirectory) else {
                return nil
            }
            let skill = members.first(where: {
                ($0.directoryPath as NSString).standardizingPath == (path as NSString).standardizingPath
            })
            let score = skill.map { priorityScore(for: $0, manualRoots: manualRoots) } ?? 99
            return (path, target, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.target < rhs.target
        }

        if let adopted = symlinkCandidates.first {
            return SkillConsolidateGroupPlan(
                folder_name: folderName,
                canonical_destination: destination,
                winner_path: adopted.target,
                relink_paths: needingWork,
                action: .adoptExternalThenRelink(externalTarget: adopted.target)
            )
        }

        return SkillConsolidateGroupPlan(
            folder_name: folderName,
            canonical_destination: destination,
            winner_path: nil,
            relink_paths: [],
            action: .conflict(reason: "no real skill directory or resolvable symlink to adopt")
        )
    }

    private nonisolated static func orderedUniquePaths(_ paths: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for path in paths {
            let standardized = (path as NSString).standardizingPath
            if seen.insert(standardized).inserted {
                result.append(standardized)
            }
        }
        return result
    }

    private nonisolated static func isSymlinkPath(_ path: String, fileManager: FileManager) -> Bool {
        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType {
            return type == .typeSymbolicLink
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private nonisolated static func resolvedSymlinkTarget(
        at path: String,
        fileManager: FileManager
    ) -> String? {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            return nil
        }
        if destination.hasPrefix("/") {
            return (destination as NSString).standardizingPath
        }
        return (URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent(destination)
            .path as NSString).standardizingPath
    }

    private nonisolated static func isSymlink(
        at path: String,
        pointingTo expected: String,
        fileManager: FileManager
    ) -> Bool {
        guard let resolved = resolvedSymlinkTarget(at: path, fileManager: fileManager) else {
            return false
        }
        return resolved == (expected as NSString).standardizingPath
    }
}
