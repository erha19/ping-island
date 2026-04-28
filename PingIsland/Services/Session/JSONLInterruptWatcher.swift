//
//  JSONLInterruptWatcher.swift
//  PingIsland
//
//  Watches JSONL files for interrupt patterns in real-time
//  Uses file system events to detect interrupts faster than hook polling
//

import Foundation
import os.log

/// Logger for interrupt watcher
private nonisolated let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Interrupt")

protocol JSONLInterruptWatcherDelegate: AnyObject {
    func didDetectInterrupt(sessionId: String)
    func didObserveFileChange(sessionId: String)
}

/// Watches a session's JSONL file for interrupt patterns in real-time
/// Uses DispatchSource for immediate detection when new lines are written
nonisolated class JSONLInterruptWatcher: @unchecked Sendable {
    private static let initialRetryDelayMs = 250
    private static let maxRetryDelayMs = 5_000

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var retryWorkItem: DispatchWorkItem?
    private var lastOffset: UInt64 = 0
    private var retryAttempt = 0
    private var loggedMissingFile = false
    private var waitingForFile = false
    private let sessionId: String
    private let filePath: String
    private let queue = DispatchQueue(label: "com.wudanwu.pingisland.interruptwatcher", qos: .userInteractive)

    weak var delegate: JSONLInterruptWatcherDelegate?

    /// Patterns that indicate an interrupt occurred
    /// We check for is_error:true combined with interrupt content
    private static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user"
    ]

    init(sessionId: String, cwd: String, explicitFilePath: String? = nil) {
        self.sessionId = sessionId
        if let explicitFilePath, !explicitFilePath.isEmpty {
            self.filePath = explicitFilePath
        } else {
            self.filePath = Self.resolveFallbackFilePath(sessionId: sessionId, cwd: cwd)
        }
    }

    static func resolveFallbackFilePath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let qoderPath = NSHomeDirectory() + "/.qoder/projects/" + projectDir + "/transcript/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderPath) {
            return qoderPath
        }

        let qoderWorkPath = NSHomeDirectory() + "/.qoderwork/projects/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderWorkPath) {
            return qoderWorkPath
        }

        if let codexPath = resolveCodexRolloutPath(sessionId: sessionId) {
            return codexPath
        }

        return NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
    }

    private static func resolveCodexRolloutPath(sessionId: String) -> String? {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        let suffix = "-\(sessionId).jsonl"
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(suffix) else { continue }
            return fileURL.path
        }

        return nil
    }

    /// Start watching the JSONL file for interrupts
    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        stopInternal()

        guard FileManager.default.fileExists(atPath: filePath) else {
            if !loggedMissingFile {
                logger.debug("Waiting for transcript file: \(self.filePath, privacy: .public)")
                loggedMissingFile = true
            }
            waitingForFile = true
            scheduleRetry()
            return
        }

        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            logger.warning("Failed to open transcript file: \(self.filePath, privacy: .public)")
            waitingForFile = true
            scheduleRetry()
            return
        }

        fileHandle = handle
        let needsInitialSync = waitingForFile
        waitingForFile = false
        retryAttempt = 0
        if loggedMissingFile {
            logger.debug("Attached transcript watcher after file became available: \(self.sessionId.prefix(8), privacy: .public)...")
            loggedMissingFile = false
        }

        do {
            lastOffset = try handle.seekToEnd()
        } catch {
            logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            try? handle.close()
            fileHandle = nil
            scheduleRetry()
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.checkForInterrupt()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()

        logger.debug("Started watching: \(self.sessionId.prefix(8), privacy: .public)...")

        if needsInitialSync {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.didObserveFileChange(sessionId: self.sessionId)
            }
        }
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        guard currentSize > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return
        }

        lastOffset = currentSize

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.didObserveFileChange(sessionId: self.sessionId)
        }

        let lines = newContent.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            if isInterruptLine(line) {
                logger.info("Detected interrupt in session: \(self.sessionId.prefix(8), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.didDetectInterrupt(sessionId: self.sessionId)
                }
                return
            }
        }
    }

    private func isInterruptLine(_ line: String) -> Bool {
        if line.contains("\"type\":\"user\"") {
            if line.contains("[Request interrupted by user]") ||
               line.contains("[Request interrupted by user for tool use]") {
                return true
            }
        }

        if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") {
            for pattern in Self.interruptContentPatterns {
                if line.contains(pattern) {
                    return true
                }
            }
        }

        if line.contains("\"interrupted\":true") {
            return true
        }

        return false
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if source != nil {
            logger.debug("Stopped watching: \(self.sessionId.prefix(8), privacy: .public)...")
        }
        source?.cancel()
        source = nil
        if fileHandle != nil {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.startWatching()
        }
        retryWorkItem = workItem
        let delay = Self.retryDelay(forMissingFileAttempt: retryAttempt)
        retryAttempt += 1
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    static func retryDelay(forMissingFileAttempt attempt: Int) -> DispatchTimeInterval {
        let boundedAttempt = max(0, min(attempt, 8))
        let multiplier = 1 << boundedAttempt
        let delayMs = min(initialRetryDelayMs * multiplier, maxRetryDelayMs)
        return .milliseconds(delayMs)
    }

    deinit {
        source?.cancel()
    }
}

// MARK: - Interrupt Watcher Manager

/// Manages interrupt watchers for all active sessions
@MainActor
class InterruptWatcherManager {
    static let shared = InterruptWatcherManager()

    private var watchers: [String: JSONLInterruptWatcher] = [:]
    weak var delegate: JSONLInterruptWatcherDelegate?

    private init() {}

    func startWatching(sessionId: String, cwd: String, explicitFilePath: String? = nil) {
        guard watchers[sessionId] == nil else { return }

        let watcher = JSONLInterruptWatcher(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        watcher.delegate = delegate
        watcher.start()
        watchers[sessionId] = watcher
    }

    /// Stop watching a specific session
    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(sessionId: String) -> Bool {
        watchers[sessionId] != nil
    }
}
