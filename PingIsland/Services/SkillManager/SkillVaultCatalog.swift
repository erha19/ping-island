//
//  SkillVaultCatalog.swift
//  PingIsland
//
//  Read-side inventory for the central skill vault.
//

import Foundation

struct SkillVaultEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    var folder_name: String
    var name: String
    var description: String?
    /// Markdown body after YAML front matter (for lightweight edit forms).
    var body: String
    var path: String
    /// True when the vault entry itself is a symlink (adopted external skill).
    var is_symlink: Bool
    /// Resolved symlink destination when `is_symlink` is true.
    var external_target: String?
    /// Agent/manual skill paths that currently symlink to this vault entry.
    var inbound_link_paths: [String]
    /// Launch uses recorded for this folder_name (Island copy-and-open).
    var use_count: Int
}

enum SkillVaultCatalog {
    nonisolated static func listEntries(
        vaultRoot: String,
        manualRoots: [String] = [],
        profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        homeDirectory: URL = UserHomeDirectoryResolver.hookConfigurationHomeDirectory,
        useCounts: [String: Int] = SkillUsageStore.load().use_counts,
        fileManager: FileManager = .default
    ) -> [SkillVaultEntry] {
        let standardizedVault = (vaultRoot as NSString).standardizingPath
        let vaultURL = URL(fileURLWithPath: standardizedVault, isDirectory: true)
        guard fileManager.fileExists(atPath: vaultURL.path) else { return [] }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: vaultURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        let inboundIndex = inboundLinksByVaultEntryPath(
            vaultRoot: standardizedVault,
            manualRoots: manualRoots,
            profiles: profiles,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )

        var entries: [SkillVaultEntry] = []
        for child in children {
            let folderName = child.lastPathComponent
            let path = child.standardizedFileURL.path
            let isSymlink = isSymlinkPath(path, fileManager: fileManager)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            guard exists || isSymlink else { continue }

            let skillMarkdown = child.appendingPathComponent("SKILL.md")
            let markdownText = (try? String(contentsOf: skillMarkdown, encoding: .utf8)) ?? ""
            let frontMatter = LocalSkillCatalog.parseFrontMatter(from: markdownText)
            let trimmedName = frontMatter.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (trimmedName?.isEmpty == false) ? trimmedName! : folderName
            let description = frontMatter.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = SkillVaultWriter.readBody(fromMarkdown: markdownText)
            let externalTarget = isSymlink ? resolvedSymlinkTarget(at: path, fileManager: fileManager) : nil

            entries.append(
                SkillVaultEntry(
                    folder_name: folderName,
                    name: resolvedName,
                    description: (description?.isEmpty == false) ? description : nil,
                    body: body,
                    path: path,
                    is_symlink: isSymlink,
                    external_target: externalTarget,
                    inbound_link_paths: inboundIndex[path] ?? [],
                    use_count: max(0, useCounts[folderName] ?? 0)
                )
            )
        }

        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Skill roots to scan for inbound agent links (excludes the vault itself).
    nonisolated static func inboundScanRoots(
        vaultRoot: String,
        manualRoots: [String],
        profiles: [ManagedHookClientProfile],
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let vaultPath = (vaultRoot as NSString).standardizingPath
        var roots: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard path != vaultPath else { return }
            guard seen.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            roots.append(url)
        }

        for relative in SkillAgentSkillsPath.defaultAutoRootRelativePaths() {
            append(homeDirectory.appendingPathComponent(relative, isDirectory: true))
        }
        for profile in profiles {
            append(SkillAgentSkillsPath.skillsDirectory(for: profile, homeDirectory: homeDirectory))
        }
        for root in manualRoots {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            append(URL(fileURLWithPath: trimmed, isDirectory: true))
        }
        return roots
    }

    nonisolated static func isSymlinkPath(_ path: String, fileManager: FileManager) -> Bool {
        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType {
            return type == .typeSymbolicLink
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    nonisolated static func resolvedSymlinkTarget(
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

    // MARK: - Private

    private nonisolated static func inboundLinksByVaultEntryPath(
        vaultRoot: String,
        manualRoots: [String],
        profiles: [ManagedHookClientProfile],
        homeDirectory: URL,
        fileManager: FileManager
    ) -> [String: [String]] {
        let vaultPath = (vaultRoot as NSString).standardizingPath
        var index: [String: [String]] = [:]

        for root in inboundScanRoots(
            vaultRoot: vaultRoot,
            manualRoots: manualRoots,
            profiles: profiles,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children {
                let path = child.standardizedFileURL.path
                guard isSymlinkPath(path, fileManager: fileManager),
                      let target = resolvedSymlinkTarget(at: path, fileManager: fileManager)
                else {
                    continue
                }
                let expectedVaultEntry = (vaultPath as NSString).appendingPathComponent(child.lastPathComponent)
                guard target == expectedVaultEntry else { continue }
                index[expectedVaultEntry, default: []].append(path)
            }
        }

        for key in index.keys {
            var seen = Set<String>()
            index[key] = (index[key] ?? []).filter { seen.insert($0).inserted }
        }
        return index
    }
}
