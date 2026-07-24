//
//  AICOSCodexActivator.swift
//  PingIsland
//
//  Opens or focuses the selected Integration agent after an AI-COS mission pack is prepared.
//

import AppKit
import Foundation

enum AICOSCodexActivator {
    @MainActor
    static func activate(
        profile: ManagedHookClientProfile?,
        workspacePath: String,
        matchingSessions: [SessionState] = [],
        workspace: NSWorkspace = .shared
    ) async -> Bool {
        guard let profile else { return false }

        if let session = preferredSession(
            profile: profile,
            workspacePath: workspacePath,
            sessions: matchingSessions
        ) {
            if await SessionLauncher.shared.activate(session) {
                return true
            }
        }

        let bundleIDs = profile.localAppBundleIdentifiers
        guard !bundleIDs.isEmpty else { return false }

        if await activateRunningApp(bundleIdentifiers: bundleIDs, workspace: workspace) {
            return true
        }

        if await openApplication(bundleIdentifiers: bundleIDs, workspace: workspace) {
            return true
        }

        if profile.id == "codex-hooks" {
            guard let url = URL(string: "codex://") else { return false }
            return workspace.open(url)
        }
        return false
    }

    static func preferredSession(
        profile: ManagedHookClientProfile,
        workspacePath: String,
        sessions: [SessionState]
    ) -> SessionState? {
        let normalizedWorkspace = normalizedPath(workspacePath)
        guard !normalizedWorkspace.isEmpty else { return nil }

        let branded = sessions.filter { $0.clientInfo.brand == profile.brand }
        return branded.first { normalizedPath($0.cwd) == normalizedWorkspace }
    }

    @MainActor
    private static func activateRunningApp(
        bundleIdentifiers: [String],
        workspace: NSWorkspace
    ) async -> Bool {
        guard let bundleIdentifier = bundleIdentifiers.first(where: { identifier in
            workspace.runningApplications.contains { $0.bundleIdentifier == identifier }
        }) else {
            return false
        }
        guard let running = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            return false
        }
        return running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @MainActor
    private static func openApplication(
        bundleIdentifiers: [String],
        workspace: NSWorkspace
    ) async -> Bool {
        for bundleIdentifier in bundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                do {
                    _ = try await workspace.openApplication(at: url, configuration: configuration)
                    return true
                } catch {
                    continue
                }
            }
        }
        return false
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
