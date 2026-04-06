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
        guard provider == .claude,
              clientInfo.kind == .claudeCode,
              clientInfo.terminalBundleIdentifier == "com.googlecode.iterm2",
              clientInfo.iTermSessionIdentifier?.isEmpty == false || clientInfo.terminalSessionIdentifier?.isEmpty == false
        else {
            return
        }

        let bundleIdentifier = "com.googlecode.iterm2"
        guard attemptedBundleIdentifiers.insert(bundleIdentifier).inserted else {
            return
        }

        Task.detached(priority: .utility) {
            await FocusDiagnosticsStore.shared.record(
                "AutomationPermission preflight-start session=\(sessionId) bundle=\(bundleIdentifier)"
            )

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

            let targetDescriptor = NSAppleEventDescriptor(
                processIdentifier: runningApplication.processIdentifier
            )
            guard let address = targetDescriptor.aeDesc else {
                await FocusDiagnosticsStore.shared.record(
                    "AutomationPermission preflight-skip-no-descriptor session=\(sessionId) bundle=\(bundleIdentifier) pid=\(runningApplication.processIdentifier)"
                )
                return
            }

            let status = AEDeterminePermissionToAutomateTarget(
                address,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                true
            )

            await FocusDiagnosticsStore.shared.record(
                "AutomationPermission preflight-result session=\(sessionId) bundle=\(bundleIdentifier) pid=\(runningApplication.processIdentifier) status=\(status)"
            )
        }
    }
}
