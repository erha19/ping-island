import Foundation

struct DiagnosticsExportResult: Sendable {
    let archiveURL: URL
    let warnings: [String]
}

actor DiagnosticsExporter {
    static let shared = DiagnosticsExporter()

    private let fileManager = FileManager.default

    private init() {}

    func exportArchive(to destinationURL: URL) async throws -> DiagnosticsExportResult {
        let timestamp = Self.archiveTimestamp()
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClaudeIsland-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        let exportRoot = tempRoot.appendingPathComponent("ClaudeIsland-Diagnostics-\(timestamp)", isDirectory: true)
        var warnings: [String] = []

        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)

        do {
            try await writeMetadata(to: exportRoot.appendingPathComponent("metadata.json"))
        } catch {
            warnings.append("Failed to write metadata: \(error.localizedDescription)")
        }

        let copiedFiles: [(source: URL, relativePath: String)] = [
            (SessionAssociationStore.diagnosticsFileURL, "state/session-associations.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"), "configs/claude-settings.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".qoder/settings.json"), "configs/qoder-settings.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json"), "configs/codex-hooks.json"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"), "configs/codex-config.toml"),
            (fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl"), "configs/codex-session-index.jsonl"),
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
                from: fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".island-debug/codex-hooks", isDirectory: true),
                toRelativeDirectory: "debug/codex-hooks",
                under: exportRoot
            )
        } catch {
            warnings.append("Failed to copy Codex hook debug logs: \(error.localizedDescription)")
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
            return name.hasPrefix("island") || name.hasPrefix("claudeisland")
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
                    "showAgentDetail": AppSettings.showAgentDetail,
                    "showUsage": AppSettings.showUsage,
                    "usageValueMode": AppSettings.usageValueMode.rawValue,
                    "contentFontSize": AppSettings.contentFontSize,
                    "maxPanelHeight": AppSettings.maxPanelHeight,
                    "soundThemeMode": AppSettings.shared.soundThemeMode.rawValue,
                    "selectedSoundPackPath": AppSettings.shared.selectedSoundPackPath,
                    "notchPetStyle": AppSettings.shared.notchPetStyle.rawValue,
                ],
            ]
        }

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destinationURL, options: [.atomic])
    }

    private func writeUnifiedLogs(to destinationURL: URL) async throws {
        let predicate = "(subsystem == \"com.wudanwu.island\") OR (subsystem == \"com.claudeisland\")"
        try await writeCommandOutput(
            executable: "/usr/bin/log",
            arguments: [
                "show",
                "--style", "compact",
                "--debug",
                "--info",
                "--last", "6h",
                "--predicate", predicate,
            ],
            to: destinationURL
        )
    }

    private func writeCommandOutput(executable: String, arguments: [String], to destinationURL: URL) async throws {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = await ProcessExecutor.shared.runWithResult(executable, arguments: arguments)
        switch result {
        case .success(let output):
            try output.output.write(to: destinationURL, atomically: true, encoding: .utf8)
            if let stderr = output.stderr, !stderr.isEmpty {
                let stderrURL = destinationURL.deletingPathExtension().appendingPathExtension("stderr.txt")
                try stderr.write(to: stderrURL, atomically: true, encoding: .utf8)
            }
        case .failure(let error):
            throw error
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
