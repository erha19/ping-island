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

/// Sessions idle for longer than this threshold are skipped on startup.
private let activeWindowSeconds: TimeInterval = 4 * 60 * 60  // 4 hours

actor ClaudeDesktopWatcher {
    static let shared = ClaudeDesktopWatcher()

    private var discoveryTask: Task<Void, Never>?
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var knownLocalSessionIds: Set<String> = []
    private var sessionFileSizes: [String: UInt64] = [:]  // localSessionId → last known file size
    private var resultScanOffsets: [String: UInt64] = [:]  // localSessionId → byte offset up to which result entries have been scanned

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard discoveryTask == nil else { return }
        logger.info("Starting Claude Desktop watcher")
        discoveryTask = Task {
            await self.runDiscoveryLoop()
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        knownLocalSessionIds.removeAll()
        sessionFileSizes.removeAll()
        resultScanOffsets.removeAll()
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
            let localSessionId = String(name.dropLast(5)) // strip .json

            guard !knownLocalSessionIds.contains(localSessionId) else { continue }

            await registerSession(metadataURL: entry, localSessionId: localSessionId)
        }
    }

    // MARK: - Session Registration

    private func registerSession(metadataURL: URL, localSessionId: String) async {
        guard let metadata = Self.readMetadata(at: metadataURL) else { return }
        guard !metadata.isArchived else { return }

        // Skip sessions that have been idle longer than the active window.
        // This prevents loading dozens of historical sessions on startup.
        let idleSeconds = Date().timeIntervalSince(metadata.lastActivityAt)
        guard idleSeconds < activeWindowSeconds else {
            logger.debug(
                "Skipping stale Claude Desktop session \(metadata.cliSessionId.prefix(8), privacy: .public) idle=\(Int(idleSeconds))s"
            )
            knownLocalSessionIds.insert(localSessionId)
            return
        }

        let sessionDir = metadataURL.deletingPathExtension()
        let auditPath = sessionDir.appendingPathComponent("audit.jsonl").path
        guard FileManager.default.fileExists(atPath: auditPath) else { return }

        knownLocalSessionIds.insert(localSessionId)
        logger.info(
            "Registering Claude Desktop session \(metadata.cliSessionId.prefix(8), privacy: .public) idle=\(Int(idleSeconds))s"
        )

        let info = ClaudeDesktopSessionInfo(
            sessionId: metadata.cliSessionId,
            cwd: metadata.cwd,
            title: metadata.title,
            createdAt: metadata.createdAt,
            auditFilePath: auditPath
        )
        await SessionStore.shared.process(.desktopSessionDiscovered(info))

        // Advance ConversationParser's internal offset to end-of-file without emitting
        // events, so we only pick up content written after Ping Island started watching.
        await ConversationParser.shared.resetState(for: metadata.cliSessionId)
        _ = await ConversationParser.shared.parseIncremental(
            sessionId: metadata.cliSessionId,
            cwd: metadata.cwd,
            explicitFilePath: auditPath
        )

        // Record current file size so the polling loop can skip unchanged files.
        let currentSize = Self.fileSize(at: auditPath)
        sessionFileSizes[localSessionId] = currentSize
        // Start result scanning from EOF — don't treat historical result entries as new completions.
        resultScanOffsets[localSessionId] = currentSize

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
            let currentSize = Self.fileSize(at: auditFilePath)
            let lastSize = sessionFileSizes[localSessionId] ?? 0

            if currentSize > lastSize {
                sessionFileSizes[localSessionId] = currentSize

                // Scan new bytes for type:"result" entries (signals AI turn completion).
                let scanFrom = resultScanOffsets[localSessionId] ?? lastSize
                if currentSize > scanFrom,
                   let turnCompleted = Self.scanForResultEntry(
                       filePath: auditFilePath, from: scanFrom, to: currentSize
                   )
                {
                    resultScanOffsets[localSessionId] = currentSize
                    logger.info(
                        "Turn completed session=\(sessionId.prefix(8), privacy: .public) isError=\(turnCompleted.isError) turns=\(turnCompleted.numTurns)"
                    )
                    await SessionStore.shared.process(.desktopTurnCompleted(sessionId: sessionId))
                } else {
                    resultScanOffsets[localSessionId] = currentSize
                }

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
            }

            // End the session when Claude Desktop archives it
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

    struct ResultEntry {
        let isError: Bool
        let numTurns: Int
    }

    /// Reads bytes [from, to) from the file and scans for the first `type:"result"` JSONL entry.
    nonisolated static func scanForResultEntry(filePath: String, from: UInt64, to: UInt64) -> ResultEntry? {
        guard to > from,
              let fh = FileHandle(forReadingAtPath: filePath)
        else { return nil }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: from)
            let length = Int(to - from)
            guard let data = try fh.read(upToCount: length),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "result"
                else { continue }
                let isError = json["is_error"] as? Bool ?? false
                let numTurns = json["num_turns"] as? Int ?? 1
                return ResultEntry(isError: isError, numTurns: numTurns)
            }
        } catch {}
        return nil
    }

    nonisolated static func fileSize(at path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

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
        let lastActivityAtMs = json["lastActivityAt"] as? TimeInterval ?? createdAtMs
        let lastActivityAt = Date(timeIntervalSince1970: lastActivityAtMs / 1000)

        return ClaudeDesktopSessionMetadata(
            localSessionId: localSessionId,
            cliSessionId: cliSessionId,
            cwd: cwd,
            title: title,
            isArchived: isArchived,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
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
    let lastActivityAt: Date
}
