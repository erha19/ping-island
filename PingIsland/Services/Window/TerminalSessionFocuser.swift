//
//  TerminalSessionFocuser.swift
//  PingIsland
//
//  Focuses a specific terminal tab/session by TTY when the host app supports scripting.
//

import AppKit
import Foundation
import os.log

actor TerminalSessionFocuser {
    static let shared = TerminalSessionFocuser()
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "TerminalFocus")

    private init() {}

    func focusSession(
        terminalPid: Int,
        tty: String?,
        candidateProcessIDs: [Int] = [],
        workspacePath: String? = nil,
        launchURL: String? = nil
    ) async -> Bool {
        guard let appInfo = await MainActor.run(body: {
            NSRunningApplication(processIdentifier: pid_t(terminalPid)).map {
                (
                    bundleIdentifier: $0.bundleIdentifier,
                    localizedName: $0.localizedName
                )
            }
        }) else {
            logger.debug("No running app found for terminal pid \(terminalPid, privacy: .public)")
            return false
        }

        let bundleIdentifier = appInfo.bundleIdentifier ?? ""
        let localizedName = appInfo.localizedName ?? ""
        let logTTY = tty ?? "unknown"

        logger.debug("Attempting scripted focus terminalPid=\(terminalPid, privacy: .public) bundle=\(bundleIdentifier, privacy: .public) tty=\(logTTY, privacy: .public)")

        if let profile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: bundleIdentifier,
            appName: localizedName
        ), IDEExtensionInstaller.isInstalled(profile) {
            if profile.prefersWorkspaceWindowRouting {
                _ = await SessionLauncher.routeIDEWorkspaceWindow(
                    detectedBundleIdentifier: bundleIdentifier,
                    appName: localizedName,
                    workspacePath: workspacePath,
                    fallbackLaunchURL: launchURL,
                    additionalBundleIdentifiers: profile.localAppBundleIdentifiers
                )
            } else {
                _ = await MainActor.run {
                    guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
                        return false
                    }

                    if app.isHidden {
                        app.unhide()
                    }

                    return app.activate(options: [])
                }
            }

            let pids = candidateProcessIDs.isEmpty ? [terminalPid] : candidateProcessIDs
            if await focusWithExtension(profile: profile, processIDs: pids) {
                logger.debug("Focused IDE terminal via URI extension profile=\(profile.id, privacy: .public) pids=\(String(describing: pids), privacy: .public)")
                return true
            }
        }

        guard let tty else {
            logger.debug("No tty available for bundle \(bundleIdentifier, privacy: .public); skipping AppleScript fallback")
            return false
        }

        switch bundleIdentifier {
        case "com.apple.Terminal":
            return await runAppleScript(lines: terminalScriptLines(for: tty))
        case "com.googlecode.iterm2":
            return await runAppleScript(lines: iTermScriptLines(for: tty))
        default:
            logger.debug("No scripted focuser for bundle \(bundleIdentifier, privacy: .public)")
            return false
        }
    }

    private func focusWithExtension(profile: ManagedIDEExtensionProfile, processIDs: [Int]) async -> Bool {
        let queryItems = processIDs
            .filter { $0 > 0 }
            .map { URLQueryItem(name: "pid", value: String($0)) }
        guard !queryItems.isEmpty,
              let url = IDEExtensionInstaller.makeURI(
                profile: profile,
                path: "/focus",
                queryItems: queryItems
              ) else {
            return false
        }

        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    private func runAppleScript(lines: [String]) async -> Bool {
        let preview = lines.joined(separator: " | ")
        logger.debug("Running AppleScript: \(preview, privacy: .public)")

        let result = await ProcessExecutor.shared.runWithResult("/usr/bin/osascript", arguments: lines.flatMap { ["-e", $0] })

        switch result {
        case .success(let processResult):
            let stdout = processResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = processResult.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.debug("AppleScript success stdout=\(stdout, privacy: .public) stderr=\(stderr, privacy: .public)")
            return stdout == "ok"
        case .failure(let error):
            logger.error("AppleScript failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func terminalScriptLines(for tty: String) -> [String] {
        let normalizedTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        let fullTTY = "/dev/\(normalizedTTY)"

        return [
            "set shortTTY to \"\(normalizedTTY)\"",
            "set fullTTY to \"\(fullTTY)\"",
            "tell application id \"com.apple.Terminal\"",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "set tabTTY to tty of theTab",
            "if tabTTY is shortTTY or tabTTY is fullTTY then",
            "set selected of theTab to true",
            "set frontmost of theWindow to true",
            "activate",
            "return \"ok\"",
            "end if",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ]
    }

    private func iTermScriptLines(for tty: String) -> [String] {
        let normalizedTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        let fullTTY = "/dev/\(normalizedTTY)"

        return [
            "set shortTTY to \"\(normalizedTTY)\"",
            "set fullTTY to \"\(fullTTY)\"",
            "tell application id \"com.googlecode.iterm2\"",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "repeat with theSession in sessions of theTab",
            "set sessionTTY to tty of theSession",
            "if sessionTTY is shortTTY or sessionTTY is fullTTY then",
            "select theSession",
            "activate",
            "return \"ok\"",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ]
    }
}
