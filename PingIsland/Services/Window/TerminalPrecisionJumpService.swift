import AppKit
import CoreGraphics
import Foundation
import os.log

actor TerminalPrecisionJumpService {
    static let shared = TerminalPrecisionJumpService()

    private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "PrecisionJump")

    private init() {}

    func focus(
        bundleIdentifier: String?,
        workspacePath: String?,
        clientInfo: SessionClientInfo
    ) async -> Bool {
        let normalizedBundle = bundleIdentifier.map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        let program = clientInfo.terminalProgram?.lowercased()

        if normalizedBundle == "dev.warp.Warp-Stable" || program?.contains("warp") == true {
            return await focusWarp(workspacePath: workspacePath)
        }

        if normalizedBundle == "com.github.wez.wezterm" || program?.contains("wezterm") == true {
            return await focusWezTermPane(clientInfo: clientInfo)
        }

        if program?.contains("kaku") == true {
            return await focusWezTermPane(clientInfo: clientInfo, executableNames: ["kak", "kaku", "wezterm"])
        }

        if program?.contains("zellij") == true || clientInfo.processName?.lowercased().contains("zellij") == true {
            return await focusZellijPane(clientInfo: clientInfo)
        }

        if let normalizedBundle,
           TerminalAppRegistry.isIDEBundle(normalizedBundle),
           await SessionLauncher.routeIDEWorkspaceWindow(
               detectedBundleIdentifier: normalizedBundle,
               appName: clientInfo.name,
               workspacePath: workspacePath,
               fallbackLaunchURL: clientInfo.launchURL
           ) {
            return true
        }

        return false
    }

    private func focusWarp(workspacePath: String?) async -> Bool {
        _ = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/open",
            arguments: ["-b", "dev.warp.Warp-Stable"]
        )

        guard let workspacePath,
              let tabIndex = await WarpTabResolver().tabIndex(forWorkspacePath: workspacePath),
              (0...8).contains(tabIndex) else {
            return true
        }

        await MainActor.run {
            Self.sendCommandDigit(tabIndex + 1)
        }
        return true
    }

    private func focusWezTermPane(
        clientInfo: SessionClientInfo,
        executableNames: [String] = ["wezterm"]
    ) async -> Bool {
        guard let paneID = clientInfo.terminalSessionIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !paneID.isEmpty else {
            return false
        }

        guard let executable = await resolveExecutable(names: executableNames) else {
            return false
        }

        let result = await ProcessExecutor.shared.runWithResult(
            executable,
            arguments: ["cli", "activate-pane", "--pane-id", paneID],
            timeout: 1.5
        )

        if case .success = result {
            return true
        }

        return false
    }

    private func focusZellijPane(clientInfo: SessionClientInfo) async -> Bool {
        guard let paneID = clientInfo.tmuxPaneIdentifier ?? clientInfo.terminalSessionIdentifier,
              !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        guard let executable = await resolveExecutable(names: ["zellij"]) else {
            return false
        }

        var arguments = ["action", "focus-pane-id", paneID]
        if let session = clientInfo.tmuxSessionIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !session.isEmpty {
            arguments = ["--session", session] + arguments
        }

        let result = await ProcessExecutor.shared.runWithResult(executable, arguments: arguments, timeout: 1.5)
        if case .success = result {
            return true
        }

        return false
    }

    private func resolveExecutable(names: [String]) async -> String? {
        let candidates = names.flatMap { name in
            [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/usr/bin/\(name)"
            ]
        }

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        for name in names {
            let result = await ProcessExecutor.shared.runWithResult(
                "/usr/bin/which",
                arguments: [name],
                timeout: 1.0
            )
            if case .success(let processResult) = result {
                let path = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }

        return nil
    }

    @MainActor
    private static func sendCommandDigit(_ digit: Int) {
        guard (1...9).contains(digit),
              let keyCode = keyCodeForDigit(digit) else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags.maskCommand
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func keyCodeForDigit(_ digit: Int) -> CGKeyCode? {
        switch digit {
        case 1: return 18
        case 2: return 19
        case 3: return 20
        case 4: return 21
        case 5: return 23
        case 6: return 22
        case 7: return 26
        case 8: return 28
        case 9: return 25
        default: return nil
        }
    }
}

struct WarpTabResolver: Sendable {
    var sqlitePath: String

    init(sqlitePath: String = WarpTabResolver.defaultSQLitePath) {
        self.sqlitePath = sqlitePath
    }

    static var defaultSQLitePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }

    nonisolated func tabIndex(forWorkspacePath workspacePath: String) async -> Int? {
        guard FileManager.default.fileExists(atPath: sqlitePath) else { return nil }

        let query = """
        SELECT COUNT(*)
        FROM tabs t2
        WHERE t2.window_id = (
          SELECT t.window_id
          FROM terminal_panes tp
          JOIN pane_nodes pn ON pn.id = tp.id
          JOIN tabs t ON t.id = pn.tab_id
          WHERE tp.cwd = '\(Self.sqlEscaped(workspacePath))'
          ORDER BY t.id ASC
          LIMIT 1
        )
        AND t2.id < (
          SELECT t.id
          FROM terminal_panes tp
          JOIN pane_nodes pn ON pn.id = tp.id
          JOIN tabs t ON t.id = pn.tab_id
          WHERE tp.cwd = '\(Self.sqlEscaped(workspacePath))'
          ORDER BY t.id ASC
          LIMIT 1
        );
        """

        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/sqlite3",
            arguments: [sqlitePath, query],
            timeout: 1.0
        )

        guard case .success(let processResult) = result else { return nil }
        return Int(processResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
