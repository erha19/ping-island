//
//  SkillSymlinkLinker.swift
//  PingIsland
//
//  Creates / verifies / removes skill symlinks under agent skills directories.
//

import Foundation

enum SkillSymlinkLinker {
    nonisolated static func linkStatus(
        skill: LocalSkill,
        profile: ManagedHookClientProfile,
        homeDirectory: URL = UserHomeDirectoryResolver.hookConfigurationHomeDirectory,
        fileManager: FileManager = .default
    ) -> SkillLinkStatus {
        let skillsDir = SkillAgentSkillsPath.skillsDirectory(for: profile, homeDirectory: homeDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: skillsDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .skillsDirectoryMissing
        }

        let linkURL = skillsDir.appendingPathComponent(skill.folderName, isDirectory: true)
        return status(at: linkURL, expectedDestination: skill.directoryPath, fileManager: fileManager)
    }

    /// Applies desired linked profile set: create missing links, remove stale managed links.
    @discardableResult
    nonisolated static func applyLinks(
        skill: LocalSkill,
        desiredProfileIDs: [String],
        profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        homeDirectory: URL = UserHomeDirectoryResolver.hookConfigurationHomeDirectory,
        fileManager: FileManager = .default
    ) -> [String: SkillLinkStatus] {
        let desired = Set(desiredProfileIDs)
        var results: [String: SkillLinkStatus] = [:]

        for profile in profiles {
            let linkURL = SkillAgentSkillsPath
                .skillsDirectory(for: profile, homeDirectory: homeDirectory)
                .appendingPathComponent(skill.folderName, isDirectory: true)

            if desired.contains(profile.id) {
                results[profile.id] = ensureLink(
                    skill: skill,
                    profile: profile,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                )
            } else if isManagedSymlink(
                at: linkURL,
                expectedDestination: skill.directoryPath,
                fileManager: fileManager
            ) {
                try? fileManager.removeItem(at: linkURL)
                results[profile.id] = .missing
            }
        }

        return results
    }

    nonisolated static func ensureLink(
        skill: LocalSkill,
        profile: ManagedHookClientProfile,
        homeDirectory: URL = UserHomeDirectoryResolver.hookConfigurationHomeDirectory,
        fileManager: FileManager = .default
    ) -> SkillLinkStatus {
        let skillsDir = SkillAgentSkillsPath.skillsDirectory(for: profile, homeDirectory: homeDirectory)
        do {
            try fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        } catch {
            return .skillsDirectoryMissing
        }

        let linkURL = skillsDir.appendingPathComponent(skill.folderName, isDirectory: true)
        let current = status(at: linkURL, expectedDestination: skill.directoryPath, fileManager: fileManager)
        switch current {
        case .linked:
            return .linked
        case .conflict:
            return current
        case .missing, .skillsDirectoryMissing:
            break
        }

        if fileManager.fileExists(atPath: linkURL.path) || isSymlink(at: linkURL, fileManager: fileManager) {
            // Replace only broken or mismatched symlinks pointing elsewhere that we can safely remove.
            if isSymlink(at: linkURL, fileManager: fileManager) {
                try? fileManager.removeItem(at: linkURL)
            } else {
                return .conflict(existingPath: linkURL.path)
            }
        }

        do {
            try fileManager.createSymbolicLink(
                at: linkURL,
                withDestinationURL: URL(fileURLWithPath: skill.directoryPath, isDirectory: true)
            )
            return .linked
        } catch {
            return .conflict(existingPath: linkURL.path)
        }
    }

    // MARK: - Private

    private nonisolated static func status(
        at linkURL: URL,
        expectedDestination: String,
        fileManager: FileManager
    ) -> SkillLinkStatus {
        if !fileManager.fileExists(atPath: linkURL.path) && !isSymlink(at: linkURL, fileManager: fileManager) {
            return .missing
        }

        if isSymlink(at: linkURL, fileManager: fileManager) {
            let destination = (try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)) ?? ""
            let resolved: String
            if destination.hasPrefix("/") {
                resolved = (destination as NSString).standardizingPath
            } else {
                resolved = linkURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(destination)
                    .standardizedFileURL
                    .path
            }
            if resolved == (expectedDestination as NSString).standardizingPath {
                return .linked
            }
            // Broken or wrong symlink — treat as missing so apply can replace.
            if !fileManager.fileExists(atPath: resolved) {
                return .missing
            }
            return .conflict(existingPath: resolved)
        }

        return .conflict(existingPath: linkURL.path)
    }

    private nonisolated static func isManagedSymlink(
        at linkURL: URL,
        expectedDestination: String,
        fileManager: FileManager
    ) -> Bool {
        guard isSymlink(at: linkURL, fileManager: fileManager) else { return false }
        if case .linked = status(
            at: linkURL,
            expectedDestination: expectedDestination,
            fileManager: fileManager
        ) {
            return true
        }
        // Also remove broken symlinks that used to point at this skill folder name.
        return true
    }

    private nonisolated static func isSymlink(at url: URL, fileManager: FileManager) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType else {
            // dangling symlink may throw on attributesOfItem — check via lstat style
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists { return false }
            return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        }
        return type == .typeSymbolicLink
    }
}
