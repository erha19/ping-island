//
//  SkillRemoteInstallService.swift
//  PingIsland
//
//  Installs a remote skill folder into the central vault.
//

import Foundation

enum SkillRemoteInstallError: Error, Equatable, LocalizedError {
    case alreadyExists(String)
    case catalogMissing
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let path):
            return "Skill already exists at \(path)"
        case .catalogMissing:
            return "Remote catalog definition missing"
        case .writeFailed(let message):
            return message
        }
    }
}

enum SkillRemoteInstallService {
    /// Installs the remote skill into `vaultRoot/<folder_name>/`.
    /// Returns the installed absolute path.
    @discardableResult
    nonisolated static func install(
        summary: SkillRemoteSkillSummary,
        vaultRoot: String,
        fetcher: any SkillRemoteHTTPFetching = SkillRemoteURLSessionFetcher(),
        fileManager: FileManager = .default
    ) async throws -> String {
        guard let catalog = SkillRemoteCatalog.definition(id: summary.catalog_id) else {
            throw SkillRemoteInstallError.catalogMissing
        }

        let vaultURL = URL(
            fileURLWithPath: (vaultRoot as NSString).standardizingPath,
            isDirectory: true
        )
        let destination = vaultURL.appendingPathComponent(summary.folder_name, isDirectory: true)
        let destinationPath = destination.path

        if fileManager.fileExists(atPath: destinationPath)
            || SkillVaultCatalog.isSymlinkPath(destinationPath, fileManager: fileManager)
        {
            throw SkillRemoteInstallError.alreadyExists(destinationPath)
        }

        let files = try await SkillRemoteCatalogClient.downloadSkillFiles(
            catalog: catalog,
            remotePath: summary.remote_path,
            fetcher: fetcher
        )

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in files {
                let fileURL = destination.appendingPathComponent(file.relative_path)
                let parent = fileURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try file.data.write(to: fileURL, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            if let installError = error as? SkillRemoteInstallError {
                throw installError
            }
            throw SkillRemoteInstallError.writeFailed(error.localizedDescription)
        }

        // Ensure SKILL.md landed; otherwise roll back.
        let skillMarkdown = destination.appendingPathComponent("SKILL.md")
        guard fileManager.fileExists(atPath: skillMarkdown.path) else {
            try? fileManager.removeItem(at: destination)
            throw SkillRemoteInstallError.writeFailed("Downloaded skill is missing SKILL.md")
        }

        return destinationPath
    }
}
