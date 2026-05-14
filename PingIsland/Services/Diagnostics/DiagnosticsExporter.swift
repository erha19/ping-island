import Foundation
import Darwin

struct DiagnosticsExportResult: Sendable {
    let archiveURL: URL
    let warnings: [String]
}

struct DiagnosticsCommandResult: Sendable {
    let output: String
    let stderr: String?
    let exitCode: Int32
}

enum DiagnosticsCommandError: Error, LocalizedError {
    case executionFailed(executable: String, exitCode: Int32, stderr: String?)
    case launchFailed(executable: String, underlying: Error)
    case timedOut(executable: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let executable, let exitCode, let stderr):
            let stderrSuffix = stderr.flatMap { $0.isEmpty ? nil : $0 }.map { ": \($0)" } ?? ""
            return "\(executable) exited with code \(exitCode)\(stderrSuffix)"
        case .launchFailed(let executable, let underlying):
            return "Failed to launch \(executable): \(underlying.localizedDescription)"
        case .timedOut(let executable, let timeout):
            return "\(executable) timed out after \(Int(timeout.rounded()))s"
        }
    }
}

enum DiagnosticsCommandRunner {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> DiagnosticsCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let state = DiagnosticsCommandState()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                state.appendStdout(data)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                state.appendStderr(data)
            }

            @Sendable func cleanupHandlers() {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
            }

            @Sendable func complete(_ result: Result<DiagnosticsCommandResult, DiagnosticsCommandError>) {
                cleanupHandlers()
                state.resume(continuation: continuation, with: result)
            }

            do {
                process.terminationHandler = { process in
                    state.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    state.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                    let result = state.makeResult(exitCode: process.terminationStatus)
                    if process.terminationStatus == 0 {
                        complete(.success(result))
                    } else {
                        complete(.failure(.executionFailed(
                            executable: executable,
                            exitCode: process.terminationStatus,
                            stderr: result.stderr
                        )))
                    }
                }

                try process.run()

                if let timeout, timeout > 0 {
                    let deadline = DispatchTime.now() + timeout
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                        guard !state.isFinished else { return }
                        cleanupHandlers()
                        terminateDiagnosticsProcess(process)
                        state.resume(
                            continuation: continuation,
                            with: .failure(.timedOut(executable: executable, timeout: timeout))
                        )
                    }
                }
            } catch {
                complete(.failure(.launchFailed(executable: executable, underlying: error)))
            }
        }
    }
}

private final class DiagnosticsCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdout.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderr.append(data)
        lock.unlock()
    }

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    func resume(
        continuation: CheckedContinuation<DiagnosticsCommandResult, Error>,
        with result: Result<DiagnosticsCommandResult, DiagnosticsCommandError>
    ) {
        guard markFinished() else { return }

        switch result {
        case .success(let output):
            continuation.resume(returning: output)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func makeResult(exitCode: Int32) -> DiagnosticsCommandResult {
        lock.lock()
        defer { lock.unlock() }

        let outputText = String(data: stdout, encoding: .utf8) ?? ""
        let stderrText = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return DiagnosticsCommandResult(
            output: outputText.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderrText?.isEmpty == true ? nil : stderrText,
            exitCode: exitCode
        )
    }
}

private func terminateDiagnosticsProcess(_ process: Process) {
    guard process.isRunning else { return }

    process.terminate()

    let deadline = Date().addingTimeInterval(0.2)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }

    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

enum DiagnosticsLogRedactor {
    nonisolated private static let sensitiveKeyFragments = [
        "api_key",
        "apikey",
        "authorization",
        "content",
        "cookie",
        "envelope",
        "input",
        "json",
        "message",
        "output",
        "password",
        "prompt",
        "raw",
        "secret",
        "stderr",
        "stdin",
        "stdout",
        "token",
    ]

    nonisolated static func sanitizedClaudeHookDebugLine(_ line: String) -> String? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return nil }

        guard let data = trimmedLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return encodedLine([
                "redacted": true,
                "parseError": "invalid-json",
                "rawByteCount": trimmedLine.utf8.count,
            ])
        }

        var sanitized: [String: Any] = [
            "redacted": true,
        ]

        sanitized["idHash"] = redactedIdentifier(stringValue(object["id"]))
        sanitized["timestamp"] = stringValue(object["timestamp"])
        sanitized["provider"] = stringValue(object["provider"])
        sanitized["clientKind"] = stringValue(object["clientKind"])
        sanitized["eventType"] = stringValue(object["eventType"])
        sanitized["sessionKeyHash"] = redactedIdentifier(stringValue(object["sessionKey"]))
        sanitized["expectsResponse"] = object["expectsResponse"] as? Bool
        sanitized["statusKind"] = stringValue(object["statusKind"])
        sanitized["title"] = textSummary(object["title"])
        sanitized["preview"] = textSummary(object["preview"])
        sanitized["arguments"] = argumentSummary(object["arguments"])
        sanitized["environmentKeys"] = dictionaryKeys(object["environment"])
        sanitized["metadata"] = metadataSummary(object["metadata"])
        sanitized["stdinRaw"] = payloadSummary(object["stdinRaw"])
        sanitized["envelopeJSON"] = payloadSummary(object["envelopeJSON"])
        sanitized["socketPathPresent"] = hasNonEmptyString(object["socketPath"])
        sanitized["deliveryOutcome"] = redactedExcerpt(stringValue(object["deliveryOutcome"]), limit: 120)

        return encodedLine(sanitized)
    }

    nonisolated static func redactedPlainText(_ text: String, limit: Int) -> String {
        redactedExcerpt(text, limit: limit) ?? ""
    }

    nonisolated private static func argumentSummary(_ value: Any?) -> [String: Any]? {
        guard let arguments = value as? [Any] else { return nil }
        let flags = arguments.compactMap { stringValue($0) }
            .filter { $0.hasPrefix("--") }
            .prefix(24)

        return [
            "count": arguments.count,
            "flags": Array(flags),
        ]
    }

    nonisolated private static func metadataSummary(_ value: Any?) -> [String: Any]? {
        guard let metadata = value as? [String: Any] else { return nil }
        let keys = metadata.keys.sorted()
        let selectedValues = metadata.reduce(into: [String: Any]()) { partial, pair in
            guard isSafeMetadataKey(pair.key),
                  let value = redactedExcerpt(stringValue(pair.value), limit: 120)
            else {
                return
            }
            partial[pair.key] = value
        }

        return [
            "keys": keys,
            "selectedValues": selectedValues,
        ]
    }

    nonisolated private static func payloadSummary(_ value: Any?) -> [String: Any] {
        guard let text = stringValue(value), !text.isEmpty else {
            return [
                "present": false,
                "byteCount": 0,
            ]
        }

        return [
            "present": true,
            "byteCount": text.utf8.count,
        ]
    }

    nonisolated private static func textSummary(_ value: Any?) -> [String: Any] {
        guard let text = stringValue(value), !text.isEmpty else {
            return [
                "present": false,
                "characterCount": 0,
            ]
        }

        return [
            "present": true,
            "characterCount": text.count,
        ]
    }

    nonisolated private static func dictionaryKeys(_ value: Any?) -> [String]? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return dictionary.keys.sorted()
    }

    nonisolated private static func isSafeMetadataKey(_ key: String) -> Bool {
        let lowercasedKey = key.lowercased()
        if sensitiveKeyFragments.contains(where: { lowercasedKey.contains($0) }) {
            return false
        }

        return [
            "client_kind",
            "client_name",
            "client_originator",
            "hook_event_name",
            "notification_type",
            "provider",
            "source",
            "status",
            "tool_name",
        ].contains(lowercasedKey)
    }

    nonisolated private static func redactedExcerpt(_ value: String?, limit: Int) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if !homePath.isEmpty {
            value = value.replacingOccurrences(of: homePath, with: "~")
        }
        value = redactingTokenLikeSubstrings(in: value)

        if value.count > limit {
            let prefix = value.prefix(limit)
            return "\(prefix)... [truncated, \(value.count) chars]"
        }

        return value
    }

    nonisolated private static func redactingTokenLikeSubstrings(in value: String) -> String {
        let patterns = [
            #"(?i)\bsk-[A-Za-z0-9_-]{6,}\b"#,
            #"(?i)\bsk-ant-[A-Za-z0-9_-]{6,}\b"#,
            #"(?i)\bgh[pousr]_[A-Za-z0-9_]{8,}\b"#,
            #"(?i)\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#,
        ]

        return patterns.reduce(value) { current, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return expression.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: "[redacted]"
            )
        }
    }

    nonisolated private static func redactedIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return "redacted:\(fnv1a64(value))"
    }

    nonisolated private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    nonisolated private static func hasNonEmptyString(_ value: Any?) -> Bool {
        guard let text = stringValue(value) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    nonisolated private static func encodedLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

actor DiagnosticsExporter {
    static let shared = DiagnosticsExporter()

    private static let maxDebugFilesPerDirectory = 3
    private static let maxDebugFileBytes = 256 * 1024
    private static let maxClaudeDebugJSONLLines = 120

    private let fileManager = FileManager.default

    private init() {}

    func exportArchive(to destinationURL: URL) async throws -> DiagnosticsExportResult {
        let timestamp = Self.archiveTimestamp()
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PingIsland-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = tempRoot.appendingPathComponent("PingIsland-Diagnostics-\(timestamp)", isDirectory: true)
        var warnings: [String] = []

        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        do {
            try await writeMetadata(to: exportRoot.appendingPathComponent("metadata.json"))
        } catch {
            warnings.append("Failed to write metadata: \(error.localizedDescription)")
        }

        do {
            try await writeLiveStateSnapshots(under: exportRoot)
        } catch {
            warnings.append("Failed to export live state snapshots: \(error.localizedDescription)")
        }

        let copiedFiles: [(source: URL, relativePath: String)] = [
            (SessionAssociationStore.diagnosticsFileURL, "state/session-associations.json"),
            (FocusDiagnosticsStore.diagnosticsFileURL, "logs/focus-debug.log"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"), "configs/claude-settings.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codebuddy/settings.json"), "configs/codebuddy-settings.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".qwen/settings.json"), "configs/qwen-settings.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".qoder/settings.json"), "configs/qoder-settings.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".qoderwork/settings.json"), "configs/qoderwork-settings.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json"), "configs/codex-hooks.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"), "configs/codex-config.toml"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl"), "configs/codex-session-index.jsonl"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/plugins/ping_island/plugin.yaml"), "configs/hermes-plugin/plugin.yaml"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/plugins/ping_island/__init__.py"), "configs/hermes-plugin/__init__.py"),
        ]

        for item in copiedFiles {
            do {
                try copyItemIfPresent(from: item.source, toRelativePath: item.relativePath, under: exportRoot)
            } catch {
                warnings.append("Failed to copy \(item.source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        do {
            try copySanitizedClaudeHookDebugLogs(
                from: preferredClaudeHookDebugDirectory(),
                toRelativeDirectory: "debug/claude-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to export Claude-compatible hook debug summaries: \(error.localizedDescription)")
        }

        do {
            try copyRecentDirectoryContentsIfPresent(
                from: preferredGeminiHookDebugDirectory(),
                toRelativeDirectory: "debug/gemini-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to export Gemini CLI hook debug summaries: \(error.localizedDescription)")
        }

        do {
            try copyRecentDirectoryContentsIfPresent(
                from: preferredCodexHookDebugDirectory(),
                toRelativeDirectory: "debug/codex-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Codex hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyRecentDirectoryContentsIfPresent(
                from: preferredCodeBuddyHookDebugDirectory(),
                toRelativeDirectory: "debug/codebuddy-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy CodeBuddy hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyRecentDirectoryContentsIfPresent(
                from: preferredCodeBuddyCLIHookDebugDirectory(),
                toRelativeDirectory: "debug/codebuddy-cli-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy CodeBuddy CLI hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyRecentDirectoryContentsIfPresent(
                from: preferredQoderHookDebugDirectory(),
                toRelativeDirectory: "debug/qoder-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Qoder hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyRecentDirectoryContentsIfPresent(
                from: preferredQoderCLIHookDebugDirectory(),
                toRelativeDirectory: "debug/qoder-cli-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Qoder CLI hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyRecentDirectoryContentsIfPresent(
                from: preferredHermesHookDebugDirectory(),
                toRelativeDirectory: "debug/hermes-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Hermes hook debug logs: \(error.localizedDescription)")
        }

        do {
            try await writeUnifiedLogs(to: exportRoot.appendingPathComponent("logs/unified.log"))
        } catch {
            warnings.append("Failed to export unified logs: \(error.localizedDescription)")
        }

        do {
            try await writeCommandOutput(
                executable: "/usr/bin/sw_vers",
                arguments: [],
                to: exportRoot.appendingPathComponent("logs/sw_vers.txt")
            )
        } catch {
            warnings.append("Failed to export sw_vers: \(error.localizedDescription)")
        }

        do {
            try copyRecentCrashReports(toRelativeDirectory: "logs/crash-reports", under: exportRoot)
        } catch {
            warnings.append("Failed to copy crash reports: \(error.localizedDescription)")
        }

        let archiveURL = destinationURL.pathExtension.lowercased() == "zip"
            ? destinationURL
            : destinationURL.appendingPathExtension("zip")

        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }

        let zipResult = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", exportRoot.path, archiveURL.path]
        )

        switch zipResult {
        case .success:
            break
        case .failure(let error):
            throw error
        }

        try? fileManager.removeItem(at: tempRoot)
        return DiagnosticsExportResult(archiveURL: archiveURL, warnings: warnings)
    }

    private func copyItemIfPresent(from sourceURL: URL, toRelativePath relativePath: String, under rootURL: URL) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }

        let destinationURL = rootURL.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func copySanitizedClaudeHookDebugLogs(from sourceURL: URL, toRelativeDirectory relativePath: String, under rootURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let destinationRoot = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let files = try recentRegularFiles(in: sourceURL, maxCount: Self.maxDebugFilesPerDirectory)
        for file in files {
            let destinationURL = destinationRoot.appendingPathComponent(file.lastPathComponent)
            if file.pathExtension.lowercased() == "jsonl" {
                try writeSanitizedClaudeHookJSONL(from: file, to: destinationURL)
            } else {
                try writeRedactedTailCopy(from: file, to: destinationURL)
            }
        }

        if !files.isEmpty {
            let readmeURL = destinationRoot.appendingPathComponent("README.txt")
            let note = """
            Claude hook debug JSONL files are exported as redacted summaries only.
            Full stdinRaw and envelopeJSON payloads are intentionally omitted; only counts, event metadata, and hashed identifiers remain.
            Export is limited to the \(Self.maxDebugFilesPerDirectory) most recent files and the last \(Self.maxClaudeDebugJSONLLines) JSONL records per file.
            """
            try note.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    private func copyRecentDirectoryContentsIfPresent(from sourceURL: URL, toRelativeDirectory relativePath: String, under rootURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let destinationRoot = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for item in try recentRegularFiles(in: sourceURL, maxCount: Self.maxDebugFilesPerDirectory) {
            let destinationURL = destinationRoot.appendingPathComponent(item.lastPathComponent)
            try writeTailCopy(from: item, to: destinationURL)
        }
    }

    private func recentRegularFiles(in directoryURL: URL, maxCount: Int) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        .sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        .prefix(maxCount)
        .map { $0 }
    }

    private func writeSanitizedClaudeHookJSONL(from sourceURL: URL, to destinationURL: URL) throws {
        let lines = try tailLines(
            from: sourceURL,
            maxLineCount: Self.maxClaudeDebugJSONLLines,
            maxBytes: Self.maxDebugFileBytes
        )
        let sanitizedLines = lines.compactMap(DiagnosticsLogRedactor.sanitizedClaudeHookDebugLine)

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (sanitizedLines.joined(separator: "\n") + "\n").write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func writeRedactedTailCopy(from sourceURL: URL, to destinationURL: URL) throws {
        let result = try tailData(from: sourceURL, maxBytes: Self.maxDebugFileBytes)
        let text = String(decoding: result.data, as: UTF8.self)
        var output = result.wasTruncated
            ? "[Ping Island diagnostics: file truncated to last \(Self.maxDebugFileBytes) bytes]\n"
            : ""
        output += DiagnosticsLogRedactor.redactedPlainText(text, limit: Self.maxDebugFileBytes)

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private func writeTailCopy(from sourceURL: URL, to destinationURL: URL) throws {
        let result = try tailData(from: sourceURL, maxBytes: Self.maxDebugFileBytes)
        var output = Data()
        if result.wasTruncated {
            output.append(Data("[Ping Island diagnostics: file truncated to last \(Self.maxDebugFileBytes) bytes]\n".utf8))
        }
        output.append(result.data)

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: destinationURL, options: .atomic)
    }

    private func tailLines(from sourceURL: URL, maxLineCount: Int, maxBytes: Int) throws -> [String] {
        let result = try tailData(from: sourceURL, maxBytes: maxBytes)
        var lines = String(decoding: result.data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if result.wasTruncated, !lines.isEmpty {
            lines.removeFirst()
        }

        return Array(lines.suffix(maxLineCount))
    }

    private func tailData(from sourceURL: URL, maxBytes: Int) throws -> (data: Data, wasTruncated: Bool) {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        let endOffset = try handle.seekToEnd()
        let byteCount = UInt64(max(0, maxBytes))
        let startOffset = endOffset > byteCount ? endOffset - byteCount : 0
        try handle.seek(toOffset: startOffset)
        let data = try handle.readToEnd() ?? Data()
        return (data, startOffset > 0)
    }

    private func copyRecentCrashReports(toRelativeDirectory relativePath: String, under rootURL: URL) throws {
        let diagnosticsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: diagnosticsDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let files = try fileManager.contentsOfDirectory(
            at: diagnosticsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix("ping island") || name.hasPrefix("pingisland")
        }
        .sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        .prefix(5)

        let destinationRoot = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for file in files {
            let destinationURL = destinationRoot.appendingPathComponent(file.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: file, to: destinationURL)
        }
    }

    private func writeMetadata(to destinationURL: URL) async throws {
        let metadata: [String: Any] = await MainActor.run {
            [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                "macOSVersion": Foundation.ProcessInfo.processInfo.operatingSystemVersionString,
                "locale": Locale.current.identifier,
                "timeZone": TimeZone.current.identifier,
                "settings": [
                    "hideInFullscreen": AppSettings.hideInFullscreen,
                    "autoHideWhenIdle": AppSettings.autoHideWhenIdle,
                    "autoCollapseOnLeave": AppSettings.autoCollapseOnLeave,
                    "smartSuppression": AppSettings.smartSuppression,
                    "autoOpenCompletionPanel": AppSettings.autoOpenCompletionPanel,
                    "showAgentDetail": AppSettings.showAgentDetail,
                    "subagentVisibilityMode": AppSettings.subagentVisibilityMode.rawValue,
                    "codexSubagentVisibilityMode": AppSettings.subagentVisibilityMode.rawValue,
                    "showUsage": AppSettings.showUsage,
                    "usageValueMode": AppSettings.usageValueMode.rawValue,
                    "contentFontSize": AppSettings.contentFontSize,
                    "maxPanelHeight": AppSettings.maxPanelHeight,
                    "soundThemeMode": AppSettings.shared.soundThemeMode.rawValue,
                    "selectedSoundPackPath": AppSettings.shared.selectedSoundPackPath,
                    "notchPetStyle": AppSettings.shared.notchPetStyle.rawValue,
                    "notchDisplayMode": AppSettings.shared.notchDisplayMode.rawValue,
                    "closedNotchTrailingContentMode": AppSettings.shared.closedNotchTrailingContentMode.rawValue,
                    "mascotOverrides": AppSettings.shared.mascotOverrides,
                ],
            ]
        }

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destinationURL, options: [.atomic])
    }

    private func writeLiveStateSnapshots(under rootURL: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let sessionSnapshots = await SessionStore.shared.diagnosticsSnapshot()
        let codexThreadSnapshots = await CodexAppServerMonitor.shared.diagnosticsSnapshot()
        let remoteEndpointSnapshots = await MainActor.run {
            RemoteConnectorManager.shared.diagnosticsSnapshot()
        }

        let sessionsURL = rootURL.appendingPathComponent("state/live-sessions.json")
        try fileManager.createDirectory(at: sessionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(sessionSnapshots).write(to: sessionsURL, options: .atomic)

        let codexThreadsURL = rootURL.appendingPathComponent("state/codex-thread-list.json")
        try fileManager.createDirectory(at: codexThreadsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(codexThreadSnapshots).write(to: codexThreadsURL, options: .atomic)

        let remoteEndpointsURL = rootURL.appendingPathComponent("state/remote-endpoints.json")
        try fileManager.createDirectory(at: remoteEndpointsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(remoteEndpointSnapshots).write(to: remoteEndpointsURL, options: .atomic)
    }

    private func writeUnifiedLogs(to destinationURL: URL) async throws {
        let predicate = "subsystem == \"com.wudanwu.pingisland\""
        try await writeCommandOutput(
            executable: "/usr/bin/log",
            arguments: [
                "show",
                "--style", "compact",
                "--debug",
                "--info",
                "--last", "10m",
                "--predicate", predicate,
            ],
            to: destinationURL,
            timeout: 15
        )
    }

    private func preferredCodexHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/codex-hooks", isDirectory: true)
    }

    private func preferredClaudeHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/claude-hooks", isDirectory: true)
    }

    private func preferredCodeBuddyHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/codebuddy-hooks", isDirectory: true)
    }

    private func preferredCodeBuddyCLIHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/codebuddy-cli-hooks", isDirectory: true)
    }

    private func preferredQoderHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/qoder-hooks", isDirectory: true)
    }

    private func preferredQoderCLIHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/qoder-cli-hooks", isDirectory: true)
    }

    private func preferredHermesHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/hermes-hooks", isDirectory: true)
    }

    private func preferredGeminiHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/gemini-hooks", isDirectory: true)
    }

    private func writeCommandOutput(
        executable: String,
        arguments: [String],
        to destinationURL: URL,
        timeout: TimeInterval? = nil
    ) async throws {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = try await DiagnosticsCommandRunner.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )

        try result.output.write(to: destinationURL, atomically: true, encoding: .utf8)
        if let stderr = result.stderr, !stderr.isEmpty {
            let stderrURL = destinationURL.deletingPathExtension().appendingPathExtension("stderr.txt")
            try stderr.write(to: stderrURL, atomically: true, encoding: .utf8)
        }
    }

    private static func archiveTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
