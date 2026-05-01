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

actor DiagnosticsExporter {
    static let shared = DiagnosticsExporter()

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
            try copyDirectoryContentsIfPresent(
                from: preferredClaudeHookDebugDirectory(),
                toRelativeDirectory: "debug/claude-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Claude-compatible hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyDirectoryContentsIfPresent(
                from: preferredCodexHookDebugDirectory(),
                toRelativeDirectory: "debug/codex-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Codex hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyDirectoryContentsIfPresent(
                from: preferredCodeBuddyHookDebugDirectory(),
                toRelativeDirectory: "debug/codebuddy-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy CodeBuddy hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyDirectoryContentsIfPresent(
                from: preferredQoderHookDebugDirectory(),
                toRelativeDirectory: "debug/qoder-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Qoder hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyDirectoryContentsIfPresent(
                from: preferredQoderCLIHookDebugDirectory(),
                toRelativeDirectory: "debug/qoder-cli-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Qoder CLI hook debug logs: \(error.localizedDescription)")
        }

        do {
            try copyDirectoryContentsIfPresent(
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

    private func copyDirectoryContentsIfPresent(from sourceURL: URL, toRelativeDirectory relativePath: String, under rootURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let destinationRoot = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let contents = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            let destinationURL = destinationRoot.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: item, to: destinationURL)
        }
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

    private func preferredQoderHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/qoder-hooks", isDirectory: true)
    }

    private func preferredQoderCLIHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/qoder-cli-hooks", isDirectory: true)
    }

    private func preferredHermesHookDebugDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ping-island-debug/hermes-hooks", isDirectory: true)
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
