//
//  ClaudeDesktopWatcher.swift
//  PingIsland
//
//  Monitors ~/Library/Application Support/Claude/local-agent-mode-sessions/
//  for Claude Desktop local-agent sessions. Pipes each session's audit.jsonl
//  through ConversationParser → SessionStore (notify-only, no hook responses).
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "ClaudeDesktop")

actor ClaudeDesktopWatcher {
    static let shared = ClaudeDesktopWatcher()

    private var discoveryTask: Task<Void, Never>?
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var knownLocalSessionIds: Set<String> = []

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard discoveryTask == nil else { return }
        logger.info("Starting Claude Desktop watcher")
        discoveryTask = Task { [weak self] in
            await self?.runDiscoveryLoop()
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        knownLocalSessionIds.removeAll()
        logger.info("Stopped Claude Desktop watcher")
    }

    // MARK: - Discovery Loop

    private func runDiscoveryLoop() async {
        while !Task.isCancelled {
            await scanForNewSessions()
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                break
            }
        }
    }

    private func scanForNewSessions() async {
        let sessionsRoot = Self.sessionsRootURL()
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else { return }

        guard let orgDirs = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for orgDir in orgDirs where orgDir.hasDirectoryPath {
            guard let userDirs = try? FileManager.default.contentsOfDirectory(
                at: orgDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for userDir in userDirs where userDir.hasDirectoryPath {
                await scanUserDirectory(userDir)
            }
        }
    }

    private func scanUserDirectory(_ userDir: URL) async {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: userDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            let localSessionId = name.dropLast(5).description // strip .json

            guard !knownLocalSessionIds.contains(localSessionId) else { continue }

            await registerSession(metadataURL: entry, localSessionId: localSessionId)
        }
    }

    // MARK: - Session Registration

    private func registerSession(metadataURL: URL, localSessionId: String) async {
        guard let metadata = Self.readMetadata(at: metadataURL) else { return }
        guard !metadata.isArchived else { return }

        let sessionDir = metadataURL.deletingPathExtension()
        let auditPath = sessionDir.appendingPathComponent("audit.jsonl").path
        guard FileManager.default.fileExists(atPath: auditPath) else { return }

        knownLocalSessionIds.insert(localSessionId)
        logger.info("Discovered Claude Desktop session \(metadata.cliSessionId.prefix(8), privacy: .public)")

        let info = ClaudeDesktopSessionInfo(
            sessionId: metadata.cliSessionId,
            cwd: metadata.cwd,
            title: metadata.title,
            createdAt: metadata.createdAt,
            auditFilePath: auditPath
        )
        await SessionStore.shared.process(.desktopSessionDiscovered(info))
        await ConversationParser.shared.resetState(for: metadata.cliSessionId)

        let sessionId = metadata.cliSessionId
        let cwd = metadata.cwd
        let task = Task {
            await self.runPollingLoop(
                sessionId: sessionId,
                cwd: cwd,
                auditFilePath: auditPath,
                metadataURL: metadataURL,
                localSessionId: localSessionId
            )
        }
        sessionTasks[localSessionId] = task
    }

    // MARK: - Polling Loop

    private func runPollingLoop(
        sessionId: String,
        cwd: String,
        auditFilePath: String,
        metadataURL: URL,
        localSessionId: String
    ) async {
        while !Task.isCancelled {
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd,
                explicitFilePath: auditFilePath
            )

            if result.clearDetected {
                await SessionStore.shared.process(.clearDetected(sessionId: sessionId))
            }

            if !result.newMessages.isEmpty || result.clearDetected {
                let payload = FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: cwd,
                    messages: result.newMessages,
                    isIncremental: !result.clearDetected,
                    completedToolIds: result.completedToolIds,
                    toolResults: result.toolResults,
                    structuredResults: result.structuredResults
                )
                await SessionStore.shared.process(.fileUpdated(payload))
            }

            // Check if session was archived so we can end it and stop polling
            if let metadata = Self.readMetadata(at: metadataURL), metadata.isArchived {
                logger.info("Claude Desktop session archived \(sessionId.prefix(8), privacy: .public)")
                await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
                break
            }

            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                break
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func sessionsRootURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    nonisolated static func readMetadata(at url: URL) -> ClaudeDesktopSessionMetadata? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let cliSessionId = json["cliSessionId"] as? String,
              let localSessionId = json["sessionId"] as? String
        else { return nil }

        let cwd = (json["cwd"] as? String) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let title = json["title"] as? String
        let isArchived = json["isArchived"] as? Bool ?? false
        let createdAtMs = json["createdAt"] as? TimeInterval ?? 0
        let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)

        return ClaudeDesktopSessionMetadata(
            localSessionId: localSessionId,
            cliSessionId: cliSessionId,
            cwd: cwd,
            title: title,
            isArchived: isArchived,
            createdAt: createdAt
        )
    }
}

// MARK: - Supporting Types

struct ClaudeDesktopSessionMetadata: Sendable {
    let localSessionId: String
    let cliSessionId: String
    let cwd: String
    let title: String?
    let isArchived: Bool
    let createdAt: Date
}
