//
//  SessionLauncher.swift
//  PingIsland
//
//  Activates the app or terminal that owns a session.
//

import AppKit
import ApplicationServices
import Foundation
import os.log

actor SessionLauncher {
    static let shared = SessionLauncher()

    nonisolated private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "SessionLauncher")
    nonisolated private static let ideWindowRoutingDelayNanoseconds: UInt64 = 250_000_000
    nonisolated private static let ideSessionActivationDelayNanoseconds: UInt64 = 1_000_000_000

    private init() {}

    func activate(_ session: SessionState) async -> Bool {
        Self.logger.debug("Activate request session=\(session.sessionId, privacy: .public) provider=\(String(describing: session.provider), privacy: .public) client=\(session.clientDisplayName, privacy: .public) pid=\(String(describing: session.pid), privacy: .public) tty=\(String(describing: session.tty), privacy: .public) inTmux=\(session.isInTmux)")
        let allowsAppFallback = allowsAppFallback(for: session)

        if shouldPrioritizeAppNavigation(for: session),
           await activatePreferredAppNavigation(for: session) {
            return true
        }

        if session.isInTmux, await activateTmuxSession(session) {
            Self.logger.debug("Activated tmux session \(session.sessionId, privacy: .public)")
            return true
        }

        if !session.isInTmux,
           let tty = session.tty,
           await activateTerminal(
               forTTY: tty,
               workspacePath: session.cwd,
               launchURL: session.clientInfo.launchURL
           ) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via tty \(tty, privacy: .public)")
            return true
        }

        if let pid = session.pid,
           await activateTerminal(
               forProcess: pid,
               workspacePath: session.cwd,
               launchURL: session.clientInfo.launchURL
           ) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via process pid \(pid, privacy: .public)")
            return true
        }

        if session.tty == nil,
           session.pid == nil,
           await activateIDEChatSession(session) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via IDE session focus")
            return true
        }

        if allowsAppFallback,
           await activatePreferredAppNavigation(for: session) {
            return true
        }

        if await activateHostedIDEFallback(for: session) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via hosted IDE fallback")
            return true
        }

        if let terminalBundleIdentifier = session.clientInfo.terminalBundleIdentifier,
           await activateApplication(bundleIdentifier: terminalBundleIdentifier) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via terminal bundle \(terminalBundleIdentifier, privacy: .public)")
            return true
        }

        if allowsAppFallback,
           let bundleIdentifier = session.clientInfo.bundleIdentifier,
           bundleIdentifier != "com.openai.codex",
           await activateApplication(bundleIdentifier: bundleIdentifier) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via fallback bundle \(bundleIdentifier, privacy: .public)")
            return true
        }

        if allowsAppFallback,
           session.provider == .codex,
           await activateApplication(bundleIdentifier: "com.openai.codex") {
            Self.logger.debug("Activated Codex bundle for session \(session.sessionId, privacy: .public)")
            return true
        }

        Self.logger.debug("Unable to activate session \(session.sessionId, privacy: .public)")
        return false
    }

    private func activateTmuxSession(_ session: SessionState) async -> Bool {
        if await WindowFinder.shared.isYabaiAvailable() {
            if let pid = session.pid,
               await YabaiController.shared.focusWindow(forClaudePid: pid) {
                return true
            }

            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                return true
            }
        }

        let tree = ProcessTreeBuilder.shared.buildTree()

        if let pid = session.pid,
           let target = await TmuxController.shared.findTmuxTarget(forClaudePid: pid) {
            _ = await TmuxController.shared.switchToPane(target: target)

            if let terminalPid = await findTmuxClientTerminal(forSession: target.session, tree: tree) {
                return await activateApplication(processIdentifier: terminalPid)
            }

            return true
        }

        if let target = await TmuxController.shared.findTmuxTarget(forWorkingDirectory: session.cwd) {
            _ = await TmuxController.shared.switchToPane(target: target)

            if let terminalPid = await findTmuxClientTerminal(forSession: target.session, tree: tree) {
                return await activateApplication(processIdentifier: terminalPid)
            }

            return true
        }

        return false
    }

    private func shouldPrioritizeAppNavigation(for session: SessionState) -> Bool {
        guard session.clientInfo.prefersAppNavigation else { return false }
        return session.clientInfo.kind == .codexApp
    }

    private func allowsAppFallback(for session: SessionState) -> Bool {
        session.clientInfo.kind != .codexCLI
    }

    private func activateHostedIDEFallback(for session: SessionState) async -> Bool {
        guard session.clientInfo.isHostedInIDE,
              let ideProfile = session.clientInfo.ideHostProfile else {
            return false
        }

        let detectedBundleIdentifier = session.clientInfo.terminalBundleIdentifier ?? session.clientInfo.bundleIdentifier
        let appName = session.clientInfo.originator ?? session.clientInfo.name ?? session.clientDisplayName
        let additionalBundleIdentifiers = [
            session.clientInfo.terminalBundleIdentifier,
            session.clientInfo.bundleIdentifier
        ]
        .compactMap { $0 }
        + ideProfile.localAppBundleIdentifiers

        return await activateIDEWindow(
            profile: ideProfile,
            detectedBundleIdentifier: detectedBundleIdentifier,
            appName: appName,
            workspacePath: session.cwd,
            fallbackLaunchURL: session.clientInfo.launchURL,
            additionalBundleIdentifiers: additionalBundleIdentifiers
        )
    }

    private func activatePreferredAppNavigation(for session: SessionState) async -> Bool {
        guard session.clientInfo.prefersAppNavigation else { return false }

        let detectedBundleIdentifier = session.clientInfo.bundleIdentifier ?? session.clientInfo.terminalBundleIdentifier
        let appName = session.clientInfo.name ?? session.clientDisplayName
        let additionalBundleIdentifiers = [
            session.clientInfo.bundleIdentifier,
            session.clientInfo.terminalBundleIdentifier
        ].compactMap { $0 }

        let ideProfile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: detectedBundleIdentifier,
            appName: appName
        )

        if let ideProfile,
        await activateIDEWindow(
            profile: ideProfile,
            detectedBundleIdentifier: detectedBundleIdentifier,
            appName: appName,
            workspacePath: session.cwd,
            fallbackLaunchURL: session.clientInfo.launchURL,
            additionalBundleIdentifiers: additionalBundleIdentifiers
        ) {
            let strategy = ideProfile.prefersWorkspaceWindowRouting ? "workspace routing" : "recent window activation"
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via IDE \(strategy, privacy: .public)")
            return true
        }

        if ideProfile == nil,
           await Self.routeIDEWorkspaceWindow(
            detectedBundleIdentifier: detectedBundleIdentifier,
            appName: appName,
            workspacePath: session.cwd,
            fallbackLaunchURL: session.clientInfo.launchURL,
            additionalBundleIdentifiers: additionalBundleIdentifiers
        ) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via workspace window routing")
            return true
        }

        let resolvedLaunchURL = session.clientInfo.launchURL
            ?? session.clientInfo.bundleIdentifier.flatMap {
                SessionClientInfo.appLaunchURL(
                    bundleIdentifier: $0,
                    sessionId: session.sessionId,
                    workspacePath: session.cwd
                )
            }

        if let launchURL = resolvedLaunchURL,
           await activateURL(launchURL) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via launch URL")

            if let bundleIdentifier = session.clientInfo.bundleIdentifier {
                _ = await activateApplication(bundleIdentifier: bundleIdentifier)
            }

            return true
        }

        if let bundleIdentifier = session.clientInfo.bundleIdentifier,
           await activateApplication(bundleIdentifier: bundleIdentifier) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via bundle \(bundleIdentifier, privacy: .public)")
            return true
        }

        return false
    }

    private func activateIDEWindow(
        profile: ManagedIDEExtensionProfile,
        detectedBundleIdentifier: String?,
        appName: String?,
        workspacePath: String?,
        fallbackLaunchURL: String?,
        additionalBundleIdentifiers: [String] = []
    ) async -> Bool {
        if profile.prefersWorkspaceWindowRouting {
            return await Self.routeIDEWorkspaceWindow(
                detectedBundleIdentifier: detectedBundleIdentifier,
                appName: appName,
                workspacePath: workspacePath,
                fallbackLaunchURL: fallbackLaunchURL,
                additionalBundleIdentifiers: additionalBundleIdentifiers
            )
        }

        for candidateBundleIdentifier in Self.ideCandidateBundleIdentifiers(
            detectedBundleIdentifier: detectedBundleIdentifier,
            appName: appName,
            additionalBundleIdentifiers: additionalBundleIdentifiers
        ) {
            if await activateApplication(
                bundleIdentifier: candidateBundleIdentifier,
                activateAllWindows: false
            ) {
                try? await Task.sleep(nanoseconds: Self.ideWindowRoutingDelayNanoseconds)
                Self.logger.debug("Activated recent IDE window bundle=\(candidateBundleIdentifier, privacy: .public)")
                return true
            }
        }

        if let fallbackLaunchURL,
           await activateURL(fallbackLaunchURL) {
            try? await Task.sleep(nanoseconds: Self.ideWindowRoutingDelayNanoseconds)
            Self.logger.debug("Activated IDE via fallback URL \(fallbackLaunchURL, privacy: .public)")
            return true
        }

        return false
    }

    private func activateTerminal(
        forProcess pid: Int,
        workspacePath: String,
        launchURL: String?
    ) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) else {
            Self.logger.debug("activateTerminal(forProcess:) failed to resolve terminal pid for process \(pid, privacy: .public)")
            return false
        }

        Self.logger.debug("activateTerminal(forProcess:) process \(pid, privacy: .public) -> terminalPid \(terminalPid, privacy: .public)")

        let resolvedTTY = tree[pid]?.tty ?? tree[terminalPid]?.tty
        let candidateProcessIDs: [Int]
        if let resolvedTTY {
            candidateProcessIDs = ProcessTreeBuilder.shared.candidateProcessIDs(forTTY: resolvedTTY, tree: tree)
        } else {
            candidateProcessIDs = Array(Set([pid, terminalPid])).sorted()
        }

        if await TerminalSessionFocuser.shared.focusSession(
            terminalPid: terminalPid,
            tty: resolvedTTY,
            candidateProcessIDs: candidateProcessIDs,
            workspacePath: workspacePath,
            launchURL: launchURL
        ) {
            Self.logger.debug("PID-focused terminal session pid=\(pid, privacy: .public) terminalPid=\(terminalPid, privacy: .public)")
            return true
        }

        return await activateApplication(processIdentifier: terminalPid)
    }

    private func activateTerminal(
        forTTY tty: String,
        workspacePath: String,
        launchURL: String?
    ) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        let candidateProcessIDs = ProcessTreeBuilder.shared.candidateProcessIDs(forTTY: tty, tree: tree)
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forTTY: tty, tree: tree) else {
            Self.logger.debug("activateTerminal(forTTY:) failed tty=\(tty, privacy: .public)")
            return false
        }

        Self.logger.debug("activateTerminal(forTTY:) tty=\(tty, privacy: .public) -> terminalPid \(terminalPid, privacy: .public)")

        if await TerminalSessionFocuser.shared.focusSession(
            terminalPid: terminalPid,
            tty: tty,
            candidateProcessIDs: candidateProcessIDs,
            workspacePath: workspacePath,
            launchURL: launchURL
        ) {
            Self.logger.debug("TTY-focused terminal session tty=\(tty, privacy: .public) terminalPid=\(terminalPid, privacy: .public)")
            return true
        }

        Self.logger.debug("Falling back to app activation for tty=\(tty, privacy: .public) terminalPid=\(terminalPid, privacy: .public)")
        return await activateApplication(processIdentifier: terminalPid)
    }

    private func findTmuxClientTerminal(forSession session: String, tree: [Int: ProcessInfo]) async -> Int? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await ProcessExecutor.shared.runOrNil(
            tmuxPath,
            arguments: ["list-clients", "-t", session, "-F", "#{client_pid}"]
        ) else {
            return nil
        }

        let clientPids = output
            .components(separatedBy: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        for clientPid in clientPids {
            if let terminalPid = await terminalAncestor(forProcess: clientPid, tree: tree) {
                return terminalPid
            }
        }

        return nil
    }

    private func terminalAncestor(forProcess pid: Int, tree: [Int: ProcessInfo]) async -> Int? {
        var currentPid = pid
        var depth = 0

        while currentPid > 1 && depth < 20 {
            guard let info = tree[currentPid] else { break }

            if await MainActor.run(body: { TerminalAppRegistry.isTerminal(info.command) }) {
                return currentPid
            }

            currentPid = info.ppid
            depth += 1
        }

        return nil
    }

    private func activateApplication(processIdentifier pid: Int, activateAllWindows: Bool = true) async -> Bool {
        if let bundleIdentifier = await MainActor.run(body: {
            NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
        }) {
            let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: bundleIdentifier)
            if normalizedBundleIdentifier != bundleIdentifier {
                Self.logger.debug("activateApplication(processIdentifier:) remapping helper bundle \(bundleIdentifier, privacy: .public) -> \(normalizedBundleIdentifier, privacy: .public)")
                return await activateApplication(
                    bundleIdentifier: normalizedBundleIdentifier,
                    activateAllWindows: activateAllWindows
                )
            }
        }

        return await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                Self.logger.debug("activateApplication(processIdentifier:) missing app for pid \(pid, privacy: .public)")
                return false
            }

            let success = activateRunningApplication(app, activateAllWindows: activateAllWindows)
            Self.logger.debug("activateApplication(processIdentifier:) pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "unknown", privacy: .public) success=\(success)")
            return success
        }
    }

    private func activateApplication(bundleIdentifier: String, activateAllWindows: Bool = true) async -> Bool {
        let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: bundleIdentifier)

        if await MainActor.run(body: {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: normalizedBundleIdentifier).first else {
                return false
            }

            return activateRunningApplication(app, activateAllWindows: activateAllWindows)
        }) {
            return true
        }

        guard let appURL = await MainActor.run(body: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalizedBundleIdentifier)
        }) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                    if let error {
                        Self.logger.error("Failed to open \(normalizedBundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        continuation.resume(returning: false)
                        return
                    }

                    Task { @MainActor in
                        let didActivate: Bool
                        if let app {
                            didActivate = self.activateRunningApplication(
                                app,
                                activateAllWindows: activateAllWindows
                            )
                        } else {
                            didActivate = true
                        }
                        continuation.resume(returning: didActivate)
                    }
                }
            }
        }
    }

    @MainActor
    private func activateRunningApplication(_ app: NSRunningApplication, activateAllWindows: Bool = true) -> Bool {
        if app.isHidden {
            app.unhide()
        }

        if activateAllWindows {
            restoreMiniaturizedWindows(for: app)
            return app.activate(options: [.activateAllWindows])
        }

        return app.activate(options: [])
    }

    @MainActor
    private func restoreMiniaturizedWindows(for app: NSRunningApplication) {
        guard AXIsProcessTrusted() else {
            Self.logger.debug("Skipping minimized-window restore for \(app.bundleIdentifier ?? "unknown", privacy: .public): accessibility not granted")
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard copyResult == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return
        }

        var restoredWindowCount = 0

        for window in windows {
            guard isWindowMiniaturized(window) else { continue }

            let result = AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )

            if result == .success {
                restoredWindowCount += 1
            }
        }

        if restoredWindowCount > 0 {
            Self.logger.debug("Restored \(restoredWindowCount, privacy: .public) minimized window(s) for \(app.bundleIdentifier ?? "unknown", privacy: .public)")
        }
    }

    @MainActor
    private func isWindowMiniaturized(_ window: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)

        guard result == .success else { return false }

        if let boolValue = minimizedValue as? Bool {
            return boolValue
        }

        if let numberValue = minimizedValue as? NSNumber {
            return numberValue.boolValue
        }

        return false
    }

    private func activateIDEChatSession(_ session: SessionState) async -> Bool {
        guard session.clientInfo.isQoderFamily else { return false }

        let bundleIdentifier = session.clientInfo.bundleIdentifier ?? session.clientInfo.terminalBundleIdentifier
        let appName = session.clientInfo.name ?? session.clientDisplayName
        guard let profile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        ),
        profile.sessionFocusStrategy == .qoderChatHistory,
        IDEExtensionInstaller.isInstalled(profile),
        let url = IDEExtensionInstaller.makeURI(
            profile: profile,
            path: "/session",
            queryItems: [URLQueryItem(name: "sessionId", value: session.sessionId)]
        ) else {
            return false
        }

        let candidateBundleIdentifiers = [
            session.clientInfo.bundleIdentifier,
            session.clientInfo.terminalBundleIdentifier
        ]
        .compactMap { $0 }
        + profile.localAppBundleIdentifiers

        let preparedIDEWindow = await activateIDEWindow(
            profile: profile,
            detectedBundleIdentifier: bundleIdentifier,
            appName: appName,
            workspacePath: session.cwd,
            fallbackLaunchURL: session.clientInfo.launchURL,
            additionalBundleIdentifiers: candidateBundleIdentifiers
        )

        if !preparedIDEWindow {
            var activatedCandidate = false

            for candidateBundleIdentifier in Self.orderedUniqueBundleIdentifiers(candidateBundleIdentifiers) {
                if await activateApplication(
                    bundleIdentifier: candidateBundleIdentifier,
                    activateAllWindows: false
                ) {
                    activatedCandidate = true
                    break
                }
            }

            if activatedCandidate {
                try? await Task.sleep(nanoseconds: Self.ideWindowRoutingDelayNanoseconds)
            }
        }

        try? await Task.sleep(nanoseconds: Self.ideSessionActivationDelayNanoseconds)

        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    private func activateURL(_ string: String) async -> Bool {
        guard let url = URL(string: string) else {
            Self.logger.debug("activateURL failed to parse \(string, privacy: .public)")
            return false
        }

        return await MainActor.run {
            let success = NSWorkspace.shared.open(url)
            Self.logger.debug("activateURL url=\(string, privacy: .public) success=\(success)")
            return success
        }
    }

    private static func ideCandidateBundleIdentifiers(
        detectedBundleIdentifier: String?,
        appName: String?,
        additionalBundleIdentifiers: [String] = []
    ) -> [String] {
        let normalizedBundleIdentifier = detectedBundleIdentifier
            .map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        let profile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: normalizedBundleIdentifier,
            appName: appName
        )

        return orderedUniqueBundleIdentifiers(
            ([normalizedBundleIdentifier].compactMap { $0 } + additionalBundleIdentifiers + (profile?.localAppBundleIdentifiers ?? []))
                .map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        )
    }

    static func routeIDEWorkspaceWindow(
        detectedBundleIdentifier: String?,
        appName: String?,
        workspacePath: String?,
        fallbackLaunchURL: String?,
        additionalBundleIdentifiers: [String] = []
    ) async -> Bool {
        let normalizedBundleIdentifier = detectedBundleIdentifier
            .map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        let profile = ClientProfileRegistry.ideExtensionProfile(
            bundleIdentifier: normalizedBundleIdentifier,
            appName: appName
        )
        let candidateBundleIdentifiers = ideCandidateBundleIdentifiers(
            detectedBundleIdentifier: detectedBundleIdentifier,
            appName: appName,
            additionalBundleIdentifiers: additionalBundleIdentifiers
        )

        if profile?.prefersWorkspaceURLRouting == true,
           let fallbackLaunchURL,
           let url = URL(string: fallbackLaunchURL) {
            let didOpenURL = await MainActor.run {
                NSWorkspace.shared.open(url)
            }

            if didOpenURL {
                Self.logger.debug("Routed IDE workspace via preferred URL \(fallbackLaunchURL, privacy: .public)")
                try? await Task.sleep(nanoseconds: Self.ideWindowRoutingDelayNanoseconds)
                return true
            }
        }

        if let workspacePath = existingLocalWorkspacePath(workspacePath) {
            for candidateBundleIdentifier in candidateBundleIdentifiers {
                let result = await ProcessExecutor.shared.runWithResult(
                    "/usr/bin/open",
                    arguments: ["-b", candidateBundleIdentifier, workspacePath]
                )

                switch result {
                case .success:
                    Self.logger.debug("Routed IDE workspace window bundle=\(candidateBundleIdentifier, privacy: .public) workspace=\(workspacePath, privacy: .public)")
                    try? await Task.sleep(nanoseconds: Self.ideWindowRoutingDelayNanoseconds)
                    return true
                case .failure(let error):
                    Self.logger.debug("Workspace routing failed bundle=\(candidateBundleIdentifier, privacy: .public) workspace=\(workspacePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard let fallbackLaunchURL,
              let url = URL(string: fallbackLaunchURL) else {
            return false
        }

        let didOpenURL = await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        if didOpenURL {
            Self.logger.debug("Routed IDE workspace via launch URL \(fallbackLaunchURL, privacy: .public)")
            try? await Task.sleep(nanoseconds: Self.ideWindowRoutingDelayNanoseconds)
        }

        return didOpenURL
    }

    private static func orderedUniqueBundleIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for bundleIdentifier in bundleIdentifiers {
            let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            let dedupeKey = normalized.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private static func existingLocalWorkspacePath(_ workspacePath: String?) -> String? {
        guard let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return workspacePath
    }
}
