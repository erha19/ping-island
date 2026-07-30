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
        if !bundleIDs.isEmpty {
            if await activateRunningApp(bundleIdentifiers: bundleIDs, workspace: workspace) {
                return true
            }

            if await openApplication(bundleIdentifiers: bundleIDs, workspace: workspace) {
                return true
            }
        }

        if let url = launchURL(for: profile) {
            return workspace.open(url)
        }
        return false
    }

    static func preferredSession(
        profile: ManagedHookClientProfile,
        workspacePath: String,
        sessions: [SessionState]
    ) -> SessionState? {
        let branded = sessions.filter { $0.clientInfo.brand == profile.brand }
        guard !branded.isEmpty else { return nil }

        let normalizedWorkspace = normalizedPath(workspacePath)
        if !normalizedWorkspace.isEmpty {
            return branded.first { normalizedPath($0.cwd) == normalizedWorkspace }
        }

        // Skill-manager style launches often omit a workspace; prefer any live
        // session for the selected agent brand before falling back to the app.
        return branded.first
    }

    /// Custom URL schemes used when bundle lookup cannot open the agent app.
    nonisolated static func launchURL(for profile: ManagedHookClientProfile) -> URL? {
        switch profile.id {
        case "codex-hooks":
            return URL(string: "codex://")
        case "zcode-hooks":
            return URL(string: "zcode://")
        default:
            return nil
        }
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
