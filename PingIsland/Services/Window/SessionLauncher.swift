//
//  SessionLauncher.swift
//  PingIsland
//
//  Activates the app or terminal that owns a session.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

actor SessionLauncher {
    static let shared = SessionLauncher()

    nonisolated private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "SessionLauncher")
    nonisolated private static let ideWindowRoutingDelayNanoseconds: UInt64 = 250_000_000
    nonisolated private static let ideSessionActivationDelayNanoseconds: UInt64 = 1_000_000_000
    nonisolated private static let ideWindowReadyPollNanoseconds: UInt64 = 50_000_000

    private init() {}

    func activate(_ session: SessionState) async -> Bool {
        guard !session.clientInfo.suppressesActivationNavigation else {
            return false
        }
        Self.logger.debug("Activate request session=\(session.sessionId, privacy: .public) provider=\(String(describing: session.provider), privacy: .public) client=\(session.clientDisplayName, privacy: .public) pid=\(String(describing: session.pid), privacy: .public) tty=\(String(describing: session.tty), privacy: .public) inTmux=\(session.isInTmux)")
        await FocusDiagnosticsStore.shared.record(
            "SessionLauncher activate session=\(session.sessionId) provider=\(session.provider.rawValue) client=\(session.clientDisplayName) pid=\(session.pid.map(String.init) ?? "nil") tty=\(session.tty ?? "nil") inTmux=\(session.isInTmux) terminalBundle=\(session.clientInfo.terminalBundleIdentifier ?? "nil") terminalSession=\(session.clientInfo.terminalSessionIdentifier ?? "nil") iTermSession=\(session.clientInfo.iTermSessionIdentifier ?? "nil")"
        )
        let allowsAppFallback = allowsAppFallback(for: session)

        if shouldPrioritizeAppNavigation(for: session),
           await activatePreferredAppNavigation(for: session) {
            return true
        }

        if session.isInTmux, await activateTmuxSession(session) {
            Self.logger.debug("Activated tmux session \(session.sessionId, privacy: .public)")
            return true
        }

        if session.isRemoteSession,
           await activateRemoteCarrierTerminal(session) {
            Self.logger.debug("Activated remote carrier terminal for session \(session.sessionId, privacy: .public)")
            return true
        }

        if !session.isInTmux,
           let tty = session.tty,
           await activateTerminal(
               sessionId: session.sessionId,
               forTTY: tty,
               clientInfo: session.clientInfo,
               workspacePath: session.cwd,
               launchURL: session.clientInfo.launchURL
           ) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via tty \(tty, privacy: .public)")
            return true
        }

        if let pid = session.pid,
           await activateTerminal(
               sessionId: session.sessionId,
               forProcess: pid,
               clientInfo: session.clientInfo,
               workspacePath: session.cwd,
               launchURL: session.clientInfo.launchURL
           ) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via process pid \(pid, privacy: .public)")
            return true
        }

        if await activateTrackedTerminalSession(session) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via tracked terminal identifiers")
            return true
        }

        if session.tty == nil,
           session.pid == nil,
           await activateIDEChatSession(session) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via IDE session focus")
            return true
        }

        if await activateHostedIDEFallback(for: session) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via hosted IDE fallback")
            return true
        }

        if allowsAppFallback,
           await activatePreferredAppNavigation(for: session) {
            return true
        }

        if let terminalBundleIdentifier = session.clientInfo.terminalBundleIdentifier,
           await activateApplication(bundleIdentifier: terminalBundleIdentifier, activateAllWindows: false) {
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
        await FocusDiagnosticsStore.shared.record("SessionLauncher activate-failed session=\(session.sessionId)")
        return false
    }

    func activateClientApplication(_ session: SessionState) async -> Bool {
        guard !session.clientInfo.suppressesActivationNavigation else {
            return false
        }
        if await activate(session) {
            return true
        }

        let candidateBundleIdentifiers = clientApplicationBundleIdentifiers(for: session)
        let resolvedLaunchURL = session.clientInfo.launchURL
            ?? session.clientInfo.bundleIdentifier.flatMap {
                SessionClientInfo.appLaunchURL(
                    bundleIdentifier: $0,
                    sessionId: session.sessionId,
                    workspacePath: session.cwd
                )
            }

        for bundleIdentifier in candidateBundleIdentifiers {
            if await activateClientFallbackApplication(bundleIdentifier: bundleIdentifier) {
                return true
            }
        }

        if let resolvedLaunchURL,
           await activateURL(resolvedLaunchURL) {
            for bundleIdentifier in candidateBundleIdentifiers {
                _ = await activateClientFallbackApplication(bundleIdentifier: bundleIdentifier)
            }
            return true
        }

        return false
    }

    private func activateTrackedTerminalSession(_ session: SessionState) async -> Bool {
        let clientInfo = session.clientInfo
        guard !session.isInTmux else {
            await FocusDiagnosticsStore.shared.record("SessionLauncher tracked-terminal skip-tmux session=\(session.sessionId)")
            return false
        }

        let trackedTerminalBundleIdentifier = clientInfo.terminalBundleIdentifier
            .map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        let terminalSessionIdentifier: String?
        if trackedTerminalBundleIdentifier == "com.mitchellh.ghostty" || trackedTerminalBundleIdentifier == "com.cmuxterm.app" {
            terminalSessionIdentifier = TerminalSessionFocuser.normalizedGhosttyTerminalIdentifier(
                clientInfo.terminalSessionIdentifier
            )
        } else {
            terminalSessionIdentifier = clientInfo.terminalSessionIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let iTermSessionIdentifier = clientInfo.iTermSessionIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard terminalSessionIdentifier?.isEmpty == false || iTermSessionIdentifier?.isEmpty == false else {
            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher tracked-terminal skip-no-identifiers session=\(session.sessionId)"
            )
            return false
        }

        guard let terminalBundleIdentifier = clientInfo.terminalBundleIdentifier else {
            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher tracked-terminal skip-no-bundle session=\(session.sessionId)"
            )
            return false
        }

        let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: terminalBundleIdentifier)
        let runningApplications = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: normalizedBundleIdentifier)
                .filter { !$0.isTerminated }
        }
        await FocusDiagnosticsStore.shared.record(
            "SessionLauncher tracked-terminal session=\(session.sessionId) bundle=\(normalizedBundleIdentifier) apps=\(runningApplications.map { String($0.processIdentifier) }.joined(separator: ",")) terminalSession=\(terminalSessionIdentifier ?? "nil") iTermSession=\(iTermSessionIdentifier ?? "nil")"
        )

        for application in runningApplications {
            if await TerminalSessionFocuser.shared.focusSession(
                terminalPid: Int(application.processIdentifier),
                tty: session.tty,
                candidateProcessIDs: [],
                sessionId: session.sessionId,
                clientInfo: clientInfo,
                workspacePath: session.cwd,
                launchURL: clientInfo.launchURL
            ) {
                await FocusDiagnosticsStore.shared.record(
                    "SessionLauncher tracked-terminal success session=\(session.sessionId) terminalPid=\(application.processIdentifier)"
                )
                return true
            }

            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher tracked-terminal focus-failed session=\(session.sessionId) terminalPid=\(application.processIdentifier)"
            )
        }

        await FocusDiagnosticsStore.shared.record("SessionLauncher tracked-terminal exhausted session=\(session.sessionId)")
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
                return await activateApplication(processIdentifier: terminalPid, activateAllWindows: false)
            }

            return true
        }

        if let target = await TmuxController.shared.findTmuxTarget(forWorkingDirectory: session.cwd) {
            _ = await TmuxController.shared.switchToPane(target: target)

            if let terminalPid = await findTmuxClientTerminal(forSession: target.session, tree: tree) {
                return await activateApplication(processIdentifier: terminalPid, activateAllWindows: false)
            }

            return true
        }

        return false
    }

    private func shouldPrioritizeAppNavigation(for session: SessionState) -> Bool {
        guard !Self.isTerminalHostedCodexSession(provider: session.provider, clientInfo: session.clientInfo) else {
            return false
        }
        guard session.clientInfo.prefersAppNavigation else { return false }
        return session.clientInfo.kind == .codexApp
    }

    private func allowsAppFallback(for session: SessionState) -> Bool {
        Self.allowsAppFallback(provider: session.provider, clientInfo: session.clientInfo)
    }

    nonisolated static func allowsAppFallback(
        provider: SessionProvider,
        clientInfo: SessionClientInfo
    ) -> Bool {
        guard !isTerminalHostedCodexSession(provider: provider, clientInfo: clientInfo) else {
            return false
        }
        return clientInfo.kind != .codexCLI
    }

    nonisolated static func isTerminalHostedCodexSession(
        provider: SessionProvider,
        clientInfo: SessionClientInfo
    ) -> Bool {
        guard provider == .codex,
              let terminalBundleIdentifier = clientInfo.terminalBundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !terminalBundleIdentifier.isEmpty else {
            return false
        }

        let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(
            for: terminalBundleIdentifier
        )
        guard normalizedBundleIdentifier != "com.openai.codex" else {
            return false
        }

        return TerminalAppRegistry.isTerminalBundle(normalizedBundleIdentifier)
            || TerminalAppRegistry.isIDEBundle(normalizedBundleIdentifier)
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

        let preparedIDEWindow = await activateIDEWindow(
            profile: ideProfile,
            detectedBundleIdentifier: detectedBundleIdentifier,
            appName: appName,
            workspacePath: session.cwd,
            fallbackLaunchURL: session.clientInfo.launchURL,
            additionalBundleIdentifiers: additionalBundleIdentifiers
        )

        if !preparedIDEWindow {
            return false
        }

        _ = await Self.waitForIDEWindowActivation(
            bundleIdentifiers: additionalBundleIdentifiers,
            timeoutNanoseconds: Self.ideSessionActivationDelayNanoseconds
        )

        if await TerminalSessionFocuser.shared.focusHostedSession(
            sessionId: session.sessionId,
            clientInfo: session.clientInfo,
            workspacePath: session.cwd
        ) {
            Self.logger.debug("Focused hosted IDE terminal for session \(session.sessionId, privacy: .public)")
        }

        return true
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
        let resolvedLaunchURL = session.clientInfo.launchURL
            ?? session.clientInfo.bundleIdentifier.flatMap {
                SessionClientInfo.appLaunchURL(
                    bundleIdentifier: $0,
                    sessionId: session.sessionId,
                    workspacePath: session.cwd
                )
            }

        // Codex thread deep links are more precise than workspace routing.
        if Self.shouldPrioritizeDirectLaunchURL(for: session.clientInfo),
           let launchURL = resolvedLaunchURL,
           await activateURL(launchURL) {
            Self.logger.debug("Activated session \(session.sessionId, privacy: .public) via prioritized launch URL")

            if let bundleIdentifier = session.clientInfo.bundleIdentifier {
                _ = await activateApplication(bundleIdentifier: bundleIdentifier)
            }

            return true
        }

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

    nonisolated static func shouldPrioritizeDirectLaunchURL(for clientInfo: SessionClientInfo) -> Bool {
        clientInfo.kind == .codexApp
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
        sessionId: String,
        forProcess pid: Int,
        clientInfo: SessionClientInfo,
        workspacePath: String,
        launchURL: String?,
        remoteHostHint: String? = nil
    ) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree) else {
            Self.logger.debug("activateTerminal(forProcess:) failed to resolve terminal pid for process \(pid, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher process-terminal unresolved session=\(sessionId) pid=\(pid)"
            )
            return false
        }

        Self.logger.debug("activateTerminal(forProcess:) process \(pid, privacy: .public) -> terminalPid \(terminalPid, privacy: .public)")
        let resolvedTerminalPid = await resolvedTerminalApplicationPID(
            from: terminalPid,
            clientInfo: clientInfo,
            tree: tree
        )

        let resolvedTTY = tree[pid]?.tty ?? tree[terminalPid]?.tty
        let candidateProcessIDs: [Int]
        if let resolvedTTY {
            candidateProcessIDs = ProcessTreeBuilder.shared.candidateProcessIDs(forTTY: resolvedTTY, tree: tree)
        } else {
            candidateProcessIDs = Array(Set([pid, terminalPid])).sorted()
        }

        if await TerminalSessionFocuser.shared.focusSession(
            terminalPid: resolvedTerminalPid,
            tty: resolvedTTY,
            candidateProcessIDs: candidateProcessIDs,
            sessionId: sessionId,
            clientInfo: clientInfo,
            workspacePath: workspacePath,
            launchURL: launchURL,
            remoteHostHint: remoteHostHint
        ) {
            Self.logger.debug("PID-focused terminal session pid=\(pid, privacy: .public) terminalPid=\(terminalPid, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher process-terminal success session=\(sessionId) pid=\(pid) terminalPid=\(terminalPid)"
            )
            return true
        }

        await FocusDiagnosticsStore.shared.record(
            "SessionLauncher process-terminal fallback-app session=\(sessionId) pid=\(pid) terminalPid=\(resolvedTerminalPid)"
        )
        return await activateApplication(processIdentifier: resolvedTerminalPid, activateAllWindows: false)
    }

    private func activateTerminal(
        sessionId: String,
        forTTY tty: String,
        clientInfo: SessionClientInfo,
        workspacePath: String,
        launchURL: String?,
        remoteHostHint: String? = nil
    ) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        let candidateProcessIDs = ProcessTreeBuilder.shared.candidateProcessIDs(forTTY: tty, tree: tree)
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forTTY: tty, tree: tree) else {
            Self.logger.debug("activateTerminal(forTTY:) failed tty=\(tty, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher tty-terminal unresolved session=\(sessionId) tty=\(tty)"
            )
            return false
        }

        Self.logger.debug("activateTerminal(forTTY:) tty=\(tty, privacy: .public) -> terminalPid \(terminalPid, privacy: .public)")
        let resolvedTerminalPid = await resolvedTerminalApplicationPID(
            from: terminalPid,
            clientInfo: clientInfo,
            tree: tree
        )

        if await TerminalSessionFocuser.shared.focusSession(
            terminalPid: resolvedTerminalPid,
            tty: tty,
            candidateProcessIDs: candidateProcessIDs,
            sessionId: sessionId,
            clientInfo: clientInfo,
            workspacePath: workspacePath,
            launchURL: launchURL,
            remoteHostHint: remoteHostHint
        ) {
            Self.logger.debug("TTY-focused terminal session tty=\(tty, privacy: .public) terminalPid=\(terminalPid, privacy: .public)")
            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher tty-terminal success session=\(sessionId) tty=\(tty) terminalPid=\(terminalPid)"
            )
            return true
        }

        Self.logger.debug("Falling back to app activation for tty=\(tty, privacy: .public) terminalPid=\(terminalPid, privacy: .public)")
        await FocusDiagnosticsStore.shared.record(
            "SessionLauncher tty-terminal fallback-app session=\(sessionId) tty=\(tty) terminalPid=\(resolvedTerminalPid)"
        )
        return await activateApplication(processIdentifier: resolvedTerminalPid, activateAllWindows: false)
    }

    private func activateRemoteCarrierTerminal(_ session: SessionState) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let carrier = ProcessTreeBuilder.shared.findInteractiveSSHCarrier(
            remoteHostHint: session.clientInfo.remoteHost,
            tree: tree
        ) else {
            let fallbackCarriers = ProcessTreeBuilder.shared.interactiveSSHCarriers(tree: tree)
            let uniqueTerminalPIDs = Set(fallbackCarriers.map(\.terminalPid))
            if uniqueTerminalPIDs.count == 1,
               let terminalPid = uniqueTerminalPIDs.first {
                let candidateProcessIDs = Array(Set(fallbackCarriers.flatMap(\.candidateProcessIDs))).sorted()
                let uniqueTTYs = Set(fallbackCarriers.compactMap(\.tty))
                let fallbackTTY = uniqueTTYs.count == 1 ? uniqueTTYs.first : nil
                let resolvedTerminalPid = await resolvedTerminalApplicationPID(
                    from: terminalPid,
                    clientInfo: session.clientInfo,
                    tree: tree
                )
                await FocusDiagnosticsStore.shared.record(
                    "SessionLauncher remote-carrier fallback-terminal session=\(session.sessionId) remoteHost=\(session.clientInfo.remoteHost ?? "nil") terminalPid=\(resolvedTerminalPid) carrierCount=\(fallbackCarriers.count) tty=\(fallbackTTY ?? "nil")"
                )

                if await TerminalSessionFocuser.shared.focusSession(
                    terminalPid: resolvedTerminalPid,
                    tty: fallbackTTY,
                    candidateProcessIDs: candidateProcessIDs,
                    sessionId: session.sessionId,
                    clientInfo: session.clientInfo,
                    workspacePath: session.cwd,
                    launchURL: session.clientInfo.launchURL,
                    remoteHostHint: session.clientInfo.remoteHost
                ) {
                    return true
                }

                return await activateApplication(processIdentifier: resolvedTerminalPid, activateAllWindows: false)
            }

            await FocusDiagnosticsStore.shared.record(
                "SessionLauncher remote-carrier unresolved session=\(session.sessionId) remoteHost=\(session.clientInfo.remoteHost ?? "nil")"
            )
            return false
        }

        await FocusDiagnosticsStore.shared.record(
            "SessionLauncher remote-carrier matched session=\(session.sessionId) remoteHost=\(session.clientInfo.remoteHost ?? "nil") sshPid=\(carrier.sshPid) terminalPid=\(carrier.terminalPid) tty=\(carrier.tty ?? "nil")"
        )
        let resolvedTerminalPid = await resolvedTerminalApplicationPID(
            from: carrier.terminalPid,
            clientInfo: session.clientInfo,
            tree: tree
        )

        if let tty = carrier.tty,
           await activateTerminal(
               sessionId: session.sessionId,
               forTTY: tty,
               clientInfo: session.clientInfo,
               workspacePath: session.cwd,
               launchURL: session.clientInfo.launchURL,
               remoteHostHint: session.clientInfo.remoteHost
           ) {
            return true
        }

        if await TerminalSessionFocuser.shared.focusSession(
            terminalPid: resolvedTerminalPid,
            tty: carrier.tty,
            candidateProcessIDs: carrier.candidateProcessIDs,
            sessionId: session.sessionId,
            clientInfo: session.clientInfo,
            workspacePath: session.cwd,
            launchURL: session.clientInfo.launchURL,
            remoteHostHint: session.clientInfo.remoteHost
        ) {
            return true
        }

        return await activateApplication(processIdentifier: resolvedTerminalPid, activateAllWindows: false)
    }

    private func resolvedTerminalApplicationPID(
        from terminalPid: Int,
        clientInfo: SessionClientInfo,
        tree: [Int: ProcessInfo]
    ) async -> Int {
        let hasRunningApplication = await MainActor.run {
            NSRunningApplication(processIdentifier: pid_t(terminalPid)) != nil
        }
        if hasRunningApplication {
            return terminalPid
        }

        let candidateBundleIdentifiers = Self.orderedUniqueBundleIdentifiers(
            [
                clientInfo.terminalBundleIdentifier,
                clientInfo.bundleIdentifier,
                tree[terminalPid].flatMap { TerminalAppRegistry.inferredBundleIdentifier(forCommand: $0.command) }
            ]
            .compactMap { $0 }
            .map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        )

        for bundleIdentifier in candidateBundleIdentifiers {
            if let runningAppPid = await MainActor.run(resultType: Int?.self, body: {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first(where: { !$0.isTerminated })
                    .map { Int($0.processIdentifier) }
            }) {
                await FocusDiagnosticsStore.shared.record(
                    "SessionLauncher remapped-terminal helperPid=\(terminalPid) bundle=\(bundleIdentifier) appPid=\(runningAppPid)"
                )
                return runningAppPid
            }
        }

        return terminalPid
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

        if let runningActivation = await MainActor.run(resultType: Bool?.self, body: {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: normalizedBundleIdentifier).first else {
                return nil
            }

            let didActivate = activateRunningApplication(app, activateAllWindows: activateAllWindows)
            if activateAllWindows,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalizedBundleIdentifier) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                    if let error {
                        Self.logger.debug("Reopen running app \(normalizedBundleIdentifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            return didActivate
        }), runningActivation {
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

    private func activateClientFallbackApplication(bundleIdentifier: String) async -> Bool {
        await activateApplication(
            bundleIdentifier: bundleIdentifier,
            activateAllWindows: Self.shouldActivateAllWindowsForClientFallback(bundleIdentifier: bundleIdentifier)
        )
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
            guard Self.isWindowMiniaturized(window) else { continue }

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
    private static func isWindowMiniaturized(_ window: AXUIElement) -> Bool {
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
            Self.logger.debug("Unable to prepare IDE window for chat session \(session.sessionId, privacy: .public)")
            return false
        }

        _ = await Self.waitForIDEWindowActivation(
            bundleIdentifiers: candidateBundleIdentifiers,
            timeoutNanoseconds: Self.ideSessionActivationDelayNanoseconds
        )

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

    private func clientApplicationBundleIdentifiers(for session: SessionState) -> [String] {
        var candidates: [String] = []

        if session.clientInfo.profileID == "qoderwork"
            || session.clientInfo.bundleIdentifier == "com.qoder.work"
            || session.clientInfo.terminalBundleIdentifier == "com.qoder.work" {
            candidates.append("com.qoder.work")
        }

        candidates.append(contentsOf: [
            session.clientInfo.bundleIdentifier,
            session.clientInfo.terminalBundleIdentifier
        ].compactMap { $0 })

        return Self.orderedUniqueBundleIdentifiers(
            candidates.map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        )
    }

    nonisolated static func shouldActivateAllWindowsForClientFallback(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty else {
            return true
        }

        let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: bundleIdentifier)
        return !TerminalAppRegistry.isTerminalBundle(normalizedBundleIdentifier)
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

    static func waitForIDEWindowActivation(
        bundleIdentifiers: [String],
        timeoutNanoseconds: UInt64 = ideSessionActivationDelayNanoseconds
    ) async -> Bool {
        let normalizedBundleIdentifiers = orderedUniqueBundleIdentifiers(
            bundleIdentifiers.map(TerminalAppRegistry.normalizedHostBundleIdentifier(for:))
        )
        guard !normalizedBundleIdentifiers.isEmpty else {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return false
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while true {
            if await MainActor.run(body: {
                isIDEWindowReady(forBundleIdentifiers: normalizedBundleIdentifiers)
            }) {
                return true
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                return false
            }

            let remaining = deadline - now
            try? await Task.sleep(nanoseconds: min(Self.ideWindowReadyPollNanoseconds, remaining))
        }
    }

    @MainActor
    private static func isIDEWindowReady(forBundleIdentifiers bundleIdentifiers: [String]) -> Bool {
        let runningApps = uniqueRunningApplications(forBundleIdentifiers: bundleIdentifiers)
            .filter { !$0.isHidden && !$0.isTerminated }

        guard !runningApps.isEmpty else {
            return false
        }

        if runningApps.contains(where: { $0.isActive }) {
            return true
        }

        for app in runningApps {
            if hasOnScreenWindow(forProcessIdentifier: Int(app.processIdentifier)) {
                return true
            }
        }

        guard AXIsProcessTrusted() else {
            return false
        }

        return runningApps.contains { hasUsableAXWindow(forProcessIdentifier: $0.processIdentifier) }
    }

    @MainActor
    private static func uniqueRunningApplications(forBundleIdentifiers bundleIdentifiers: [String]) -> [NSRunningApplication] {
        var seenProcessIdentifiers: Set<pid_t> = []
        var applications: [NSRunningApplication] = []

        for bundleIdentifier in bundleIdentifiers {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                guard seenProcessIdentifiers.insert(app.processIdentifier).inserted else { continue }
                applications.append(app)
            }
        }

        return applications
    }

    private static func hasOnScreenWindow(forProcessIdentifier processIdentifier: Int) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                continue
            }

            let isOnScreen = (window[kCGWindowIsOnscreen as String] as? Int) == 1
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            guard isOnScreen, alpha > 0 else { continue }

            if let bounds = window[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double,
               let height = bounds["Height"] as? Double,
               width > 40,
               height > 40 {
                return true
            }
        }

        return false
    }

    @MainActor
    private static func hasUsableAXWindow(forProcessIdentifier processIdentifier: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(processIdentifier)

        if let focusedWindow = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute),
           !Self.isWindowMiniaturized(focusedWindow) {
            return true
        }

        if let mainWindow = copyAXElement(appElement, attribute: kAXMainWindowAttribute),
           !Self.isWindowMiniaturized(mainWindow) {
            return true
        }

        guard let windows = copyAXWindows(appElement) else {
            return false
        }

        return windows.contains { !Self.isWindowMiniaturized($0) }
    }

    @MainActor
    private static func copyAXWindows(_ appElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? [AXUIElement]
    }

    @MainActor
    private static func copyAXElement(_ appElement: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value)
        guard result == .success,
              let value else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

}
