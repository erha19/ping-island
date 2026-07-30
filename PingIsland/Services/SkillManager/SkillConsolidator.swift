//
//  SkillConsolidator.swift
//  PingIsland
//
//  Executes a SkillConsolidatePlan: move winners into the vault and relink origins.
//

import Foundation

enum SkillConsolidator {
    nonisolated static func execute(
        _ plan: SkillConsolidatePlan,
        fileManager: FileManager = .default
    ) -> SkillConsolidateResult {
        var moved: [String] = []
        var adopted: [String] = []
        var relinked: [String] = []
        var skipped: [String] = []
        var conflicts: [String] = []

        let vaultURL = URL(fileURLWithPath: plan.vault_root, isDirectory: true)
        do {
            try fileManager.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        } catch {
            return SkillConsolidateResult(
                moved: [],
                adopted: [],
                relinked: [],
                skipped: [],
                conflicts: ["无法创建中央库：\(plan.vault_root)"]
            )
        }

        for group in plan.groups {
            switch group.action {
            case .skipAlreadyLinked:
                skipped.append(group.folder_name)
                continue
            case .conflict(let reason):
                conflicts.append("\(group.folder_name): \(reason)")
                continue
            case .relinkOnly:
                for path in group.relink_paths {
                    if relink(path: path, to: group.canonical_destination, fileManager: fileManager) {
                        relinked.append(path)
                    } else {
                        conflicts.append("\(path): relink failed")
                    }
                }
            case .adoptExternalThenRelink(let externalTarget):
                let destination = group.canonical_destination
                if fileManager.fileExists(atPath: destination) || isSymlink(at: destination, fileManager: fileManager) {
                    conflicts.append("\(group.folder_name): vault destination already exists")
                    continue
                }
                if createSymlink(at: destination, to: externalTarget, fileManager: fileManager) {
                    adopted.append(destination)
                } else {
                    conflicts.append("\(group.folder_name): failed to adopt \(externalTarget)")
                    continue
                }
                for path in group.relink_paths {
                    if (path as NSString).standardizingPath == (destination as NSString).standardizingPath {
                        continue
                    }
                    if relink(path: path, to: destination, fileManager: fileManager) {
                        relinked.append(path)
                    } else {
                        conflicts.append("\(path): relink failed")
                    }
                }
            case .moveThenRelink:
                guard let winner = group.winner_path else {
                    conflicts.append("\(group.folder_name): missing winner")
                    continue
                }
                let destination = group.canonical_destination
                do {
                    if fileManager.fileExists(atPath: destination) {
                        conflicts.append("\(group.folder_name): destination appeared before move")
                        continue
                    }
                    try fileManager.moveItem(
                        at: URL(fileURLWithPath: winner, isDirectory: true),
                        to: URL(fileURLWithPath: destination, isDirectory: true)
                    )
                    moved.append(winner)
                    if createSymlink(at: winner, to: destination, fileManager: fileManager) {
                        relinked.append(winner)
                    } else {
                        conflicts.append("\(winner): moved but failed to recreate symlink")
                    }
                } catch {
                    conflicts.append("\(winner): move failed (\(error.localizedDescription))")
                    continue
                }

                for path in group.relink_paths {
                    if relink(path: path, to: destination, fileManager: fileManager) {
                        relinked.append(path)
                    } else {
                        conflicts.append("\(path): relink failed")
                    }
                }
            }
        }

        return SkillConsolidateResult(
            moved: moved,
            adopted: adopted,
            relinked: relinked,
            skipped: skipped,
            conflicts: conflicts
        )
    }

    // MARK: - Private

    private nonisolated static func relink(
        path: String,
        to destination: String,
        fileManager: FileManager
    ) -> Bool {
        let standardizedPath = (path as NSString).standardizingPath
        let standardizedDestination = (destination as NSString).standardizingPath
        if standardizedPath == standardizedDestination {
            return true
        }

        if isSymlink(at: standardizedPath, fileManager: fileManager) {
            try? fileManager.removeItem(atPath: standardizedPath)
        } else if fileManager.fileExists(atPath: standardizedPath) {
            // Losing duplicate real directories are replaced after preview confirmation.
            do {
                try fileManager.removeItem(atPath: standardizedPath)
            } catch {
                return false
            }
        }

        return createSymlink(at: standardizedPath, to: standardizedDestination, fileManager: fileManager)
    }

    private nonisolated static func createSymlink(
        at path: String,
        to destination: String,
        fileManager: FileManager
    ) -> Bool {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(
                atPath: path,
                withDestinationPath: destination
            )
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func isSymlink(at path: String, fileManager: FileManager) -> Bool {
        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType {
            return type == .typeSymbolicLink
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
