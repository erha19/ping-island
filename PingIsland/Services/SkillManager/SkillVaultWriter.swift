//
//  SkillVaultWriter.swift
//  PingIsland
//
//  Creates and updates owned (non-symlink) vault skills with lightweight SKILL.md metadata.
//

import Foundation

struct SkillVaultDraft: Equatable, Sendable {
    var folder_name: String
    var name: String
    var description: String
    var body: String

    init(
        folder_name: String = "",
        name: String = "",
        description: String = "",
        body: String = ""
    ) {
        self.folder_name = folder_name
        self.name = name
        self.description = description
        self.body = body
    }
}

enum SkillVaultWriterError: Error, Equatable, LocalizedError {
    case invalidFolderName(String)
    case alreadyExists(String)
    case missingPath(String)
    case symlinkNotEditable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolderName(let message):
            return message
        case .alreadyExists(let path):
            return "Skill already exists at \(path)"
        case .missingPath(let path):
            return "Skill path missing: \(path)"
        case .symlinkNotEditable(let path):
            return "Symlink skills cannot be edited in-app: \(path)"
        case .writeFailed(let message):
            return message
        }
    }
}

enum SkillVaultWriter {
    /// Returns an error message when invalid; nil when valid.
    nonisolated static func validateFolderName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "folder_name is required"
        }
        let pattern = #"^[a-z0-9][a-z0-9_-]*$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return "folder_name must match [a-z0-9][a-z0-9_-]*"
        }
        return nil
    }

    nonisolated static func renderSKILLMarkdown(
        name: String,
        description: String,
        body: String
    ) -> String {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["---"]
        lines.append("name: \(yamlScalar(resolvedName))")
        if !resolvedDescription.isEmpty {
            lines.append("description: \(yamlScalar(resolvedDescription))")
        }
        lines.append("---")
        lines.append("")
        if !resolvedBody.isEmpty {
            lines.append(resolvedBody)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func readBody(fromMarkdown markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let withoutOpening = String(normalized.dropFirst(3))
        guard let endRange = withoutOpening.range(of: "\n---") else {
            return ""
        }
        let after = withoutOpening[endRange.upperBound...]
        let body = after.hasPrefix("\n") ? String(after.dropFirst()) : String(after)
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    nonisolated static func create(
        draft: SkillVaultDraft,
        vaultRoot: String,
        fileManager: FileManager = .default
    ) throws -> String {
        if let error = validateFolderName(draft.folder_name) {
            throw SkillVaultWriterError.invalidFolderName(error)
        }
        let folderName = draft.folder_name.trimmingCharacters(in: .whitespacesAndNewlines)
        let vaultURL = URL(
            fileURLWithPath: (vaultRoot as NSString).standardizingPath,
            isDirectory: true
        )
        let skillURL = vaultURL.appendingPathComponent(folderName, isDirectory: true)
        let skillPath = skillURL.path

        if fileManager.fileExists(atPath: skillPath)
            || SkillVaultCatalog.isSymlinkPath(skillPath, fileManager: fileManager)
        {
            throw SkillVaultWriterError.alreadyExists(skillPath)
        }

        do {
            try fileManager.createDirectory(at: skillURL, withIntermediateDirectories: true)
        } catch {
            throw SkillVaultWriterError.writeFailed(error.localizedDescription)
        }

        let resolvedName = {
            let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? folderName : trimmed
        }()
        let markdown = renderSKILLMarkdown(
            name: resolvedName,
            description: draft.description,
            body: draft.body
        )
        let markdownURL = skillURL.appendingPathComponent("SKILL.md")
        do {
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            throw SkillVaultWriterError.writeFailed(error.localizedDescription)
        }
        return skillPath
    }

    nonisolated static func update(
        path: String,
        name: String,
        description: String,
        body: String,
        fileManager: FileManager = .default
    ) throws {
        let standardized = (path as NSString).standardizingPath
        if SkillVaultCatalog.isSymlinkPath(standardized, fileManager: fileManager) {
            throw SkillVaultWriterError.symlinkNotEditable(standardized)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SkillVaultWriterError.missingPath(standardized)
        }

        let folderName = URL(fileURLWithPath: standardized).lastPathComponent
        let resolvedName = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? folderName : trimmed
        }()
        let markdown = renderSKILLMarkdown(
            name: resolvedName,
            description: description,
            body: body
        )
        let markdownURL = URL(fileURLWithPath: standardized, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        do {
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            throw SkillVaultWriterError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private nonisolated static func yamlScalar(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let needsQuote = value.contains(":")
            || value.contains("#")
            || value.contains("\"")
            || value.contains("'")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
            || value.contains("\n")
        guard needsQuote else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
