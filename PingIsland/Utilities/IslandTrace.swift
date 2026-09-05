//
//  IslandTrace.swift
//  PingIsland
//
//  One timeline for "why did the island do that?", readable after the fact.
//
//  A Claude Code session's phase is inferred, not reported: the desktop app
//  delivers only `PreToolUse`, `PostToolUse`, and `PermissionRequest`, so the
//  phase moves on tool hooks, on transcript reads, and on the liveness sweep —
//  and a session can be superseded, deleted, and re-created underneath all of
//  that. None of it is visible when the island opens or chimes for a session the
//  user considered finished. These traces put every transition and every
//  presentation decision on one clock so the sequence can be replayed.
//
//  Two sinks, on purpose:
//
//  - The unified log, for live tailing and predicate queries:
//        log stream --predicate 'subsystem == "com.wudanwu.pingisland" AND category == "Trace"'
//  - A plain-text file under `~/.ping-island-debug/island-trace/`, because a whole
//    incident can be handed over as one file, and because retention is then ours:
//    the unified log's window is a machine-wide setting, while this directory keeps
//    `retentionWindow` and prunes itself.
//
//  Rules for adding to this: log at `.notice` so lines survive to disk without
//  `--info --debug`; emit one flat `key=value` line per event; keep keys short and
//  stable, because these are read as a timeline, not as prose. Tracing must never
//  affect the app, so every file operation here fails silently.
//

import Foundation
import os.log

nonisolated enum IslandTrace {
    private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Trace")

    /// How much history the on-disk trace keeps.
    ///
    /// Long enough to cover an incident the user only noticed afterwards, short
    /// enough that the directory never becomes something to clean up by hand.
    /// Rotation is hourly, so between three and four hours are actually on disk.
    static let retentionWindow: TimeInterval = 3 * 60 * 60

    private static let fileSink = IslandTraceFileSink(retentionWindow: retentionWindow)

    /// Emit one timeline line. `fields` is a flat `key=value key=value` string.
    static func emit(_ kind: String, _ fields: String) {
        logger.notice("\(kind, privacy: .public) \(fields, privacy: .public)")
        fileSink.append("\(kind) \(fields)")
    }

    /// Directory the on-disk trace is written to.
    static var traceDirectory: URL { IslandTraceFileSink.directory }

    /// Short session tag. Matches the 8-character prefix the bridge debug log uses,
    /// so lines can be joined against `~/.ping-island-debug/*-hooks/*.jsonl`.
    static func tag(_ sessionId: String) -> String {
        String(sessionId.prefix(8))
    }

    static func tag(_ session: SessionState) -> String {
        tag(session.sessionId)
    }

    /// Collapse free text to a single field-safe token.
    static func text(_ value: String?, limit: Int = 60) -> String {
        guard let value else { return "-" }
        let collapsed = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return "-" }
        return String(collapsed.prefix(limit))
    }

    static func phase(_ phase: SessionPhase?) -> String {
        guard let phase else { return "none" }
        return phase.description
    }

    /// Everything about a session that decides whether it may notify, be hidden, or
    /// be replaced — the inputs the presentation and supersession rules read.
    static func snapshot(_ session: SessionState, now: Date = Date()) -> String {
        let interventionKind: String = {
            guard let intervention = session.intervention else { return "none" }
            return "\(intervention.kind)"
        }()
        return [
            "phase=\(phase(session.phase))",
            "provider=\(session.provider.rawValue)",
            "ingress=\(session.ingress.rawValue)",
            "pid=\(session.pid.map(String.init) ?? "none")",
            "attention=\(session.needsAttention)",
            "prompt=\(session.needsPromptNotification)",
            "intervention=\(interventionKind)",
            "completedReady=\(SessionCompletionStateEvaluator.isCompletedReadySession(session))",
            "liveExec=\(session.hasLiveExecutionEvidence(asOf: now))",
            "hidden=\(session.shouldHideFromPrimaryUI)",
            "items=\(session.chatItems.count)",
            "idleFor=\(Int(now.timeIntervalSince(session.lastActivity)))s",
            "age=\(Int(now.timeIntervalSince(session.createdAt)))s"
        ].joined(separator: " ")
    }

    static func ids(_ ids: some Collection<String>, limit: Int = 6) -> String {
        guard !ids.isEmpty else { return "-" }
        let shown = ids.prefix(limit).map { tag($0) }.joined(separator: ",")
        return ids.count > limit ? "\(shown),+\(ids.count - limit)" : shown
    }
}

/// Appends trace lines to an hourly file and drops files older than the retention
/// window.
///
/// Rotation is hourly rather than by size so pruning can be decided from the file's
/// modification date alone: a file untouched for longer than the window contains only
/// lines older than the window, which makes "delete it" trivially correct and keeps
/// the pruner from ever reading or rewriting a file.
private final class IslandTraceFileSink: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ping-island-debug/island-trace", isDirectory: true)

    /// Serial: owns the handle, the current hour, and the prune clock.
    private let queue = DispatchQueue(label: "com.wudanwu.pingisland.island-trace", qos: .utility)
    private let retentionWindow: TimeInterval
    private let pruneInterval: TimeInterval = 10 * 60

    private var handle: FileHandle?
    private var openHourKey: String?
    private var lastPrunedAt: Date = .distantPast

    private let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HH"
        return formatter
    }()

    private let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(retentionWindow: TimeInterval) {
        self.retentionWindow = retentionWindow
    }

    func append(_ line: String) {
        let now = Date()
        queue.async { [self] in
            guard let handle = openHandle(for: now) else { return }
            let stamped = "\(stampFormatter.string(from: now)) \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
            pruneIfNeeded(now: now)
        }
    }

    private func openHandle(for date: Date) -> FileHandle? {
        let hourKey = hourFormatter.string(from: date)
        if hourKey == openHourKey, let handle { return handle }

        try? self.handle?.close()
        self.handle = nil
        openHourKey = nil

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        let url = Self.directory.appendingPathComponent("island-trace-\(hourKey).log")
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? opened.seekToEnd()

        handle = opened
        openHourKey = hourKey
        return opened
    }

    private func pruneIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastPrunedAt) >= pruneInterval else { return }
        lastPrunedAt = now

        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = now.addingTimeInterval(-retentionWindow)
        for url in entries where url.pathExtension == "log" {
            // Never delete the file currently being written to, whatever its stamp.
            guard url.lastPathComponent != openHourKey.map({ "island-trace-\($0).log" }) else {
                continue
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modifiedAt, modifiedAt < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
