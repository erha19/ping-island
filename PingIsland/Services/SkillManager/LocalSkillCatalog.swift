//
//  LocalSkillCatalog.swift
//  PingIsland
//
//  Discovers local skills (SKILL.md) from auto roots, profile skills dirs, and manual roots.
//

import Foundation

enum LocalSkillCatalog {
    nonisolated static func discover(
        manualRoots: [String],
        profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        homeDirectory: URL = UserHomeDirectoryResolver.hookConfigurationHomeDirectory,
        fileManager: FileManager = .default,
        maxDepth: Int = SkillManagerConstants.maxScanDepth
    ) -> [LocalSkill] {
        var roots: [(url: URL, label: String)] = []

        for relative in SkillAgentSkillsPath.defaultAutoRootRelativePaths() {
            let url = homeDirectory.appendingPathComponent(relative, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                roots.append((url, relativeLabel(relative)))
            }
        }

        let pluginsRoot = homeDirectory.appendingPathComponent(".cursor/plugins", isDirectory: true)
        if let pluginDirs = try? fileManager.contentsOfDirectory(
            at: pluginsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for pluginDir in pluginDirs {
                let skills = pluginDir.appendingPathComponent("skills", isDirectory: true)
                if fileManager.fileExists(atPath: skills.path) {
                    roots.append((skills, "cursor-plugin/\(pluginDir.lastPathComponent)"))
                }
            }
        }

        for profile in profiles {
            let url = SkillAgentSkillsPath.skillsDirectory(for: profile, homeDirectory: homeDirectory)
            if fileManager.fileExists(atPath: url.path) {
                roots.append((url, profile.title))
            }
        }

        for root in manualRoots {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let url = URL(fileURLWithPath: trimmed, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                roots.append((url, "manual"))
            }
        }

        var byID: [String: LocalSkill] = [:]
        for root in roots {
            for skill in scan(root: root.url, sourceLabel: root.label, fileManager: fileManager, maxDepth: maxDepth) {
                if byID[skill.id] == nil {
                    byID[skill.id] = skill
                }
            }
        }

        return byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func scan(
        root: URL,
        sourceLabel: String,
        fileManager: FileManager = .default,
        maxDepth: Int = SkillManagerConstants.maxScanDepth
    ) -> [LocalSkill] {
        var results: [LocalSkill] = []
        scanDirectory(
            root,
            sourceLabel: sourceLabel,
            depth: 0,
            maxDepth: maxDepth,
            fileManager: fileManager,
            into: &results
        )
        return results
    }

    nonisolated static func parseFrontMatter(from markdown: String) -> (name: String?, description: String?) {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return (nil, nil) }
        let afterOpen = normalized.dropFirst(4)
        guard let endRange = afterOpen.range(of: "\n---") else { return (nil, nil) }
        let yaml = String(afterOpen[..<endRange.lowerBound])
        var name: String?
        var description: String?
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("name:") {
                name = scalarValue(afterPrefix: "name:", in: line)
            } else if line.hasPrefix("description:") {
                description = scalarValue(afterPrefix: "description:", in: line)
            }
        }
        return (name, description)
    }

    // MARK: - Private

    private nonisolated static func scanDirectory(
        _ directory: URL,
        sourceLabel: String,
        depth: Int,
        maxDepth: Int,
        fileManager: FileManager,
        into results: inout [LocalSkill]
    ) {
        let skillMarkdown = directory.appendingPathComponent("SKILL.md")
        if fileManager.fileExists(atPath: skillMarkdown.path) {
            if let skill = makeSkill(
                directory: directory,
                skillMarkdown: skillMarkdown,
                sourceLabel: sourceLabel
            ) {
                results.append(skill)
            }
            return
        }

        guard depth < maxDepth else { return }
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for child in children {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            scanDirectory(
                child,
                sourceLabel: sourceLabel,
                depth: depth + 1,
                maxDepth: maxDepth,
                fileManager: fileManager,
                into: &results
            )
        }
    }

    private nonisolated static func makeSkill(
        directory: URL,
        skillMarkdown: URL,
        sourceLabel: String
    ) -> LocalSkill? {
        let standardized = directory.standardizedFileURL.path
        let markdownText = (try? String(contentsOf: skillMarkdown, encoding: .utf8)) ?? ""
        let frontMatter = parseFrontMatter(from: markdownText)
        let folderName = directory.lastPathComponent
        let name = frontMatter.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false) ? name! : folderName
        let description = frontMatter.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSkill(
            id: standardized,
            name: resolvedName,
            description: (description?.isEmpty == false) ? description : nil,
            directoryPath: standardized,
            skillMarkdownPath: skillMarkdown.standardizedFileURL.path,
            sourceLabel: sourceLabel
        )
    }

    private nonisolated static func scalarValue(afterPrefix prefix: String, in line: String) -> String {
        var value = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private nonisolated static func relativeLabel(_ relative: String) -> String {
        relative
            .split(separator: "/")
            .prefix(2)
            .joined(separator: "/")
    }
}
