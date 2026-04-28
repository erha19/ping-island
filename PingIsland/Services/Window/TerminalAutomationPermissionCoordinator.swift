import AppKit
import Foundation
import CoreServices

actor TerminalAutomationPermissionCoordinator {
    static let shared = TerminalAutomationPermissionCoordinator()

    private var attemptedBundleIdentifiers: Set<String> = []

    private init() {}

    func prepareIfNeeded(
        provider: SessionProvider,
        clientInfo: SessionClientInfo,
        sessionId: String
    ) {
        guard provider == .claude || provider == .codex,
              let bundleIdentifier = Self.scriptableTerminalBundleIdentifier(for: clientInfo)
        else {
            return
        }

        Task.detached(priority: .utility) {
            await self.preflightIfNeeded(bundleIdentifier: bundleIdentifier, sessionId: sessionId)
        }
    }

    func ensurePermissionIfNeeded(
        terminalPid: Int,
        bundleIdentifier: String,
        sessionId: String?
    ) async -> Bool {
        guard Self.isAutomationPermissionRequired(bundleIdentifier: bundleIdentifier) else {
            return true
        }

        guard let runningApplication = await MainActor.run(body: {
            NSRunningApplication(processIdentifier: pid_t(terminalPid))
        }), !runningApplication.isTerminated else {
            await FocusDiagnosticsStore.shared.record(
                "AutomationPermission focus-skip-no-running-app session=\(sessionId ?? "nil") bundle=\(bundleIdentifier) terminalPid=\(terminalPid)"
            )
            return false
        }

        let status = await determinePermissionStatus(
            for: runningApplication,
            askUserIfNeeded: true,
            phase: "focus",
            sessionId: sessionId
        )
        return status == noErr
    }

    static func scriptableTerminalBundleIdentifier(for clientInfo: SessionClientInfo) -> String? {
        switch clientInfo.terminalBundleIdentifier {
        case "com.apple.Terminal":
            return "com.apple.Terminal"
        case "com.googlecode.iterm2":
            if clientInfo.iTermSessionIdentifier?.isEmpty == false
                || clientInfo.terminalSessionIdentifier?.isEmpty == false {
                return "com.googlecode.iterm2"
            }
            return nil
        case "com.mitchellh.ghostty":
            return "com.mitchellh.ghostty"
        case "com.cmuxterm.app":
            return "com.cmuxterm.app"
        default:
            return nil
        }
    }

    static func isAutomationPermissionRequired(bundleIdentifier: String) -> Bool {
        switch bundleIdentifier {
        case "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.cmuxterm.app":
            return true
        default:
            return false
        }
    }

    private func preflightIfNeeded(bundleIdentifier: String, sessionId: String) async {
        let runningApplication = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first { !$0.isTerminated }
        }

        guard let runningApplication else {
            await FocusDiagnosticsStore.shared.record(
                "AutomationPermission preflight-skip-no-running-app session=\(sessionId) bundle=\(bundleIdentifier)"
            )
            return
        }

        guard attemptedBundleIdentifiers.insert(bundleIdentifier).inserted else {
            return
        }

        let status = await determinePermissionStatus(
            for: runningApplication,
            askUserIfNeeded: true,
            phase: "preflight",
            sessionId: sessionId
        )

        if status != noErr {
            attemptedBundleIdentifiers.remove(bundleIdentifier)
        }
    }

    private func determinePermissionStatus(
        for runningApplication: NSRunningApplication,
        askUserIfNeeded: Bool,
        phase: String,
        sessionId: String?
    ) async -> OSStatus {
        let bundleIdentifier = runningApplication.bundleIdentifier ?? "unknown"
        await FocusDiagnosticsStore.shared.record(
            "AutomationPermission \(phase)-start session=\(sessionId ?? "nil") bundle=\(bundleIdentifier) pid=\(runningApplication.processIdentifier) prompt=\(askUserIfNeeded)"
        )

        let targetDescriptor = NSAppleEventDescriptor(
            processIdentifier: runningApplication.processIdentifier
        )
        guard let address = targetDescriptor.aeDesc else {
            await FocusDiagnosticsStore.shared.record(
                "AutomationPermission \(phase)-skip-no-descriptor session=\(sessionId ?? "nil") bundle=\(bundleIdentifier) pid=\(runningApplication.processIdentifier)"
            )
            return OSStatus(procNotFound)
        }

        let status = AEDeterminePermissionToAutomateTarget(
            address,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )

        await FocusDiagnosticsStore.shared.record(
            "AutomationPermission \(phase)-result session=\(sessionId ?? "nil") bundle=\(bundleIdentifier) pid=\(runningApplication.processIdentifier) status=\(status)"
        )
        return status
    }
}
