//
//  ClaudeDesktopSessionIndex.swift
//  PingIsland
//
//  Maps a Claude CLI session id onto the Claude desktop app session that hosts it.
//  The desktop app keeps one metadata file per session under
//  ~/Library/Application Support/Claude/{claude-code-sessions,local-agent-mode-sessions}/<org>/<account>/local_<uuid>.json
//  where `sessionId` is the desktop (tab) id and `cliSessionId` is the id Ping Island
//  receives from hooks. With that mapping we can deep-link to the exact tab
//  (`claude://claude.ai/epitaxy/<localSessionId>`) instead of only raising the app.
//

import Foundation
import os.log

actor ClaudeDesktopSessionIndex {
    static let shared = ClaudeDesktopSessionIndex()

    nonisolated static let appBundleIdentifier = "com.anthropic.claudefordesktop"
    nonisolated static let localSessionPrefix = "local_"

    nonisolated private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "ClaudeDesktopIndex")
    nonisolated private static let refreshInterval: TimeInterval = 2

    struct Entry: Equatable, Sendable {
        let localSessionId: String
        let cliSessionIds: [String]
        let isArchived: Bool
        let lastActivityAt: Date
    }

    private struct CachedFile {
        let modifiedAt: Date
        let size: UInt64
        let entry: Entry?
    }

    private let roots: [URL]
    private var cachedFiles: [String: CachedFile] = [:]
    private var entriesByCLISessionId: [String: Entry] = [:]
    private var lastRefreshedAt: Date?

    init(roots: [URL] = ClaudeDesktopSessionIndex.defaultRoots()) {
        self.roots = roots
    }

    // MARK: - Lookup

    /// Deep link that focuses the desktop tab hosting `cliSessionId`, if the app still has one.
    func tabDeepLink(forCLISessionId cliSessionId: String) -> String? {
        guard let localSessionId = localSessionIdentifier(forCLISessionId: cliSessionId) else { return nil }
        return Self.tabDeepLink(localSessionId: localSessionId)
    }

    func localSessionIdentifier(forCLISessionId cliSessionId: String) -> String? {
        let normalized = cliSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        refreshIfNeeded()
        return entriesByCLISessionId[normalized]?.localSessionId
    }

    /// Forces the next lookup to re-read the desktop app's metadata files.
    func invalidate() {
        lastRefreshedAt = nil
    }

    // MARK: - Deep link

    nonisolated static func tabDeepLink(localSessionId: String) -> String? {
        let trimmed = localSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !encoded.isEmpty else {
            return nil
        }
        // `/epitaxy/<id>` is the route the desktop app itself uses for a session
        // (`getSessionRoute`), and its URL handler turns it into an in-app navigate.
        // `/code/<id>` used to work by falling through to a generic handler, but as of
        // Claude 1.46 it triggers a full page load that lands on the last-focused tab.
        return "claude://claude.ai/epitaxy/\(encoded)"
    }

    nonisolated static func defaultRoots() -> [URL] {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude")
        return [
            supportDirectory.appendingPathComponent("claude-code-sessions"),
            supportDirectory.appendingPathComponent("local-agent-mode-sessions")
        ]
    }

    // MARK: - Refresh

    private func refreshIfNeeded() {
        if let lastRefreshedAt, Date().timeIntervalSince(lastRefreshedAt) < Self.refreshInterval {
            return
        }
        refresh()
    }

    private func refresh() {
        lastRefreshedAt = Date()

        var seenPaths: Set<String> = []
        var files: [String: CachedFile] = [:]
        var mapping: [String: Entry] = [:]

        for metadataURL in Self.metadataFileURLs(in: roots) {
            let path = metadataURL.path
            guard seenPaths.insert(path).inserted else { continue }

            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modifiedAt = (attributes?[.modificationDate] as? Date) ?? .distantPast
            let size = (attributes?[.size] as? UInt64) ?? 0

            let cached: CachedFile
            if let previous = cachedFiles[path], previous.modifiedAt == modifiedAt, previous.size == size {
                cached = previous
            } else {
                cached = CachedFile(modifiedAt: modifiedAt, size: size, entry: Self.parseEntry(at: metadataURL))
            }
            files[path] = cached

            guard let entry = cached.entry, !entry.isArchived else { continue }
            for cliSessionId in entry.cliSessionIds {
                if let existing = mapping[cliSessionId], existing.lastActivityAt >= entry.lastActivityAt {
                    continue
                }
                mapping[cliSessionId] = entry
            }
        }

        cachedFiles = files
        entriesByCLISessionId = mapping
        Self.logger.debug("Indexed \(files.count) Claude Desktop session files, \(mapping.count) CLI session ids")
    }

    /// `<root>/<org>/<account>/local_*.json` — walked explicitly so we never descend into
    /// the sibling session directories, which hold multi-megabyte transcripts.
    nonisolated static func metadataFileURLs(in roots: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var results: [URL] = []

        func directories(in url: URL) -> [URL] {
            let contents = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter { $0.hasDirectoryPath }
        }

        for root in roots where fileManager.fileExists(atPath: root.path) {
            for organizationDirectory in directories(in: root) {
                for accountDirectory in directories(in: organizationDirectory) {
                    let contents = (try? fileManager.contentsOfDirectory(
                        at: accountDirectory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    results.append(contentsOf: contents.filter {
                        $0.lastPathComponent.hasPrefix(localSessionPrefix)
                            && $0.pathExtension == "json"
                    })
                }
            }
        }

        return results
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated static func parseEntry(at url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseEntry(json: json)
    }

    nonisolated static func parseEntry(json: [String: Any]) -> Entry? {
        guard let localSessionId = trimmed(json["sessionId"] as? String),
              localSessionId.hasPrefix(localSessionPrefix) else {
            return nil
        }

        var cliSessionIds: [String] = []
        var seen: Set<String> = []
        func append(_ value: String?) {
            guard let value = trimmed(value), seen.insert(value).inserted else { return }
            cliSessionIds.append(value)
        }

        append(json["cliSessionId"] as? String)
        append(json["unarchivedCliSessionId"] as? String)
        append(json["preClearCliSessionId"] as? String)
        // Sessions adopted from a terminal are stored as `local_<cliSessionId>`.
        append(String(localSessionId.dropFirst(localSessionPrefix.count)))

        guard !cliSessionIds.isEmpty else { return nil }

        let milliseconds = (json["lastActivityAt"] as? TimeInterval)
            ?? (json["createdAt"] as? TimeInterval)
            ?? 0

        return Entry(
            localSessionId: localSessionId,
            cliSessionIds: cliSessionIds,
            isArchived: json["isArchived"] as? Bool ?? false,
            lastActivityAt: Date(timeIntervalSince1970: milliseconds / 1000)
        )
    }
}
