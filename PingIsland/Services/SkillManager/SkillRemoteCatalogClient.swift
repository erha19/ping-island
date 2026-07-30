//
//  SkillRemoteCatalogClient.swift
//  PingIsland
//
//  Lists and downloads skills from allowlisted public GitHub repositories.
//

import Foundation

enum SkillRemoteCatalogError: Error, Equatable, LocalizedError {
    case catalogNotAllowlisted
    case invalidResponse(String)
    case httpStatus(Int)
    case emptySkill
    case pathEscape

    var errorDescription: String? {
        switch self {
        case .catalogNotAllowlisted:
            return "Catalog is not in the allowlist"
        case .invalidResponse(let detail):
            return "Invalid GitHub response: \(detail)"
        case .httpStatus(let code):
            return "GitHub HTTP \(code)"
        case .emptySkill:
            return "Remote skill has no files"
        case .pathEscape:
            return "Remote path escapes skill directory"
        }
    }
}

protocol SkillRemoteHTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct SkillRemoteURLSessionFetcher: SkillRemoteHTTPFetching {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum SkillRemoteCatalogClient {
    nonisolated static func listSkills(
        catalog: SkillRemoteCatalogDefinition,
        includeMetadata: Bool = true,
        fetcher: any SkillRemoteHTTPFetching = SkillRemoteURLSessionFetcher()
    ) async throws -> [SkillRemoteSkillSummary] {
        try assertAllowlisted(catalog)
        let tree = try await fetchRecursiveTree(catalog: catalog, fetcher: fetcher)
        var summaries = skillSummaries(from: tree, catalog: catalog)

        if includeMetadata {
            summaries = try await withThrowingTaskGroup(
                of: (Int, SkillRemoteSkillSummary).self
            ) { group in
                for (index, summary) in summaries.enumerated() {
                    group.addTask {
                        var copy = summary
                        copy.name = summary.folder_name
                        if let markdown = try? await fetchRawFile(
                            catalog: catalog,
                            path: "\(summary.remote_path)/SKILL.md",
                            fetcher: fetcher
                        ),
                           let text = String(data: markdown, encoding: .utf8)
                        {
                            let frontMatter = LocalSkillCatalog.parseFrontMatter(from: text)
                            let name = frontMatter.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let description = frontMatter.description?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if let name, !name.isEmpty {
                                copy.name = name
                            }
                            copy.description = (description?.isEmpty == false) ? description : nil
                        }
                        return (index, copy)
                    }
                }
                var ordered = summaries
                for try await (index, summary) in group {
                    ordered[index] = summary
                }
                return ordered
            }
        }

        return summaries.sorted {
            ($0.name ?? $0.folder_name).localizedCaseInsensitiveCompare($1.name ?? $1.folder_name)
                == .orderedAscending
        }
    }

    /// Downloads all blob files under `remotePath` as (relative_path, data) pairs.
    nonisolated static func downloadSkillFiles(
        catalog: SkillRemoteCatalogDefinition,
        remotePath: String,
        fetcher: any SkillRemoteHTTPFetching = SkillRemoteURLSessionFetcher()
    ) async throws -> [(relative_path: String, data: Data)] {
        try assertAllowlisted(catalog)
        let standardizedRemote = normalizeRemotePath(remotePath)
        guard !standardizedRemote.isEmpty else { throw SkillRemoteCatalogError.emptySkill }

        let tree = try await fetchRecursiveTree(catalog: catalog, fetcher: fetcher)
        let prefix = standardizedRemote + "/"
        let blobs = tree.tree.filter { entry in
            entry.type == "blob" && entry.path.hasPrefix(prefix)
        }
        guard !blobs.isEmpty else { throw SkillRemoteCatalogError.emptySkill }

        var files: [(relative_path: String, data: Data)] = []
        for entry in blobs {
            let relative = String(entry.path.dropFirst(prefix.count))
            guard !relative.isEmpty,
                  !relative.contains(".."),
                  !(relative as NSString).isAbsolutePath
            else {
                throw SkillRemoteCatalogError.pathEscape
            }
            let data = try await fetchRawFile(
                catalog: catalog,
                path: entry.path,
                fetcher: fetcher
            )
            files.append((relative_path: relative, data: data))
        }

        if files.isEmpty { throw SkillRemoteCatalogError.emptySkill }
        return files.sorted { $0.relative_path < $1.relative_path }
    }

    // MARK: - Parsing (testable without network)

    nonisolated static func skillSummaries(
        from tree: GitTreeResponse,
        catalog: SkillRemoteCatalogDefinition
    ) -> [SkillRemoteSkillSummary] {
        let roots = catalog.skills_roots.map(normalizeRemotePath).filter { !$0.isEmpty }
        var byPath: [String: SkillRemoteSkillSummary] = [:]

        for entry in tree.tree where entry.type == "blob" {
            guard entry.path.hasSuffix("/SKILL.md") else { continue }
            let parent = (entry.path as NSString).deletingLastPathComponent
            let normalizedParent = normalizeRemotePath(parent)
            guard roots.contains(where: { normalizedParent.hasPrefix($0 + "/") }) else { continue }
            let folderName = URL(fileURLWithPath: normalizedParent).lastPathComponent
            guard !folderName.isEmpty else { continue }
            byPath[normalizedParent] = SkillRemoteSkillSummary(
                catalog_id: catalog.id,
                folder_name: folderName,
                remote_path: normalizedParent,
                name: nil,
                description: nil
            )
        }

        return Array(byPath.values)
    }

    // MARK: - Private

    private nonisolated static func assertAllowlisted(_ catalog: SkillRemoteCatalogDefinition) throws {
        guard SkillRemoteCatalog.builtIn.contains(where: {
            $0.id == catalog.id
                && $0.owner == catalog.owner
                && $0.repo == catalog.repo
        }) else {
            throw SkillRemoteCatalogError.catalogNotAllowlisted
        }
    }

    private nonisolated static func fetchRecursiveTree(
        catalog: SkillRemoteCatalogDefinition,
        fetcher: any SkillRemoteHTTPFetching
    ) async throws -> GitTreeResponse {
        let url = URL(string:
            "https://api.github.com/repos/\(catalog.owner)/\(catalog.repo)/git/trees/\(catalog.default_ref)?recursive=1"
        )!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PingIsland-SkillManager", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetcher.data(for: request)
        try throwIfNeeded(response: response)
        do {
            return try JSONDecoder().decode(GitTreeResponse.self, from: data)
        } catch {
            throw SkillRemoteCatalogError.invalidResponse(error.localizedDescription)
        }
    }

    private nonisolated static func fetchRawFile(
        catalog: SkillRemoteCatalogDefinition,
        path: String,
        fetcher: any SkillRemoteHTTPFetching
    ) async throws -> Data {
        let encodedPath = path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let url = URL(string:
            "https://raw.githubusercontent.com/\(catalog.owner)/\(catalog.repo)/\(catalog.default_ref)/\(encodedPath)"
        )!
        var request = URLRequest(url: url)
        request.setValue("PingIsland-SkillManager", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetcher.data(for: request)
        try throwIfNeeded(response: response)
        return data
    }

    private nonisolated static func throwIfNeeded(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw SkillRemoteCatalogError.httpStatus(http.statusCode)
        }
    }

    private nonisolated static func normalizeRemotePath(_ path: String) -> String {
        path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "//", with: "/")
    }
}

struct GitTreeResponse: Codable, Equatable, Sendable {
    var sha: String?
    var truncated: Bool?
    var tree: [GitTreeEntry]
}

struct GitTreeEntry: Codable, Equatable, Sendable {
    var path: String
    var mode: String?
    var type: String
    var sha: String?
    var size: Int?
}
