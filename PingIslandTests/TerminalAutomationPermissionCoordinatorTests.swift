import XCTest
@testable import Ping_Island

final class TerminalAutomationPermissionCoordinatorTests: XCTestCase {
    func testScriptableTerminalBundleIdentifierIncludesTerminalApp() {
        let clientInfo = SessionClientInfo(
            kind: .claudeCode,
            terminalBundleIdentifier: "com.apple.Terminal",
            terminalProgram: "Apple_Terminal"
        )

        XCTAssertEqual(
            TerminalAutomationPermissionCoordinator.scriptableTerminalBundleIdentifier(for: clientInfo),
            "com.apple.Terminal"
        )
    }

    func testScriptableTerminalBundleIdentifierRequiresTrackedITermSession() {
        let missingIdentifiers = SessionClientInfo(
            kind: .claudeCode,
            terminalBundleIdentifier: "com.googlecode.iterm2",
            terminalProgram: "iTerm.app"
        )
        let trackedSession = SessionClientInfo(
            kind: .claudeCode,
            terminalBundleIdentifier: "com.googlecode.iterm2",
            terminalProgram: "iTerm.app",
            terminalSessionIdentifier: "iterm-session-1"
        )

        XCTAssertNil(
            TerminalAutomationPermissionCoordinator.scriptableTerminalBundleIdentifier(for: missingIdentifiers)
        )
        XCTAssertEqual(
            TerminalAutomationPermissionCoordinator.scriptableTerminalBundleIdentifier(for: trackedSession),
            "com.googlecode.iterm2"
        )
    }

    func testAutomationPermissionRequirementMatchesScriptedTerminalBundles() {
        XCTAssertTrue(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.apple.Terminal"
            )
        )
        XCTAssertTrue(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
        XCTAssertTrue(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.mitchellh.ghostty"
            )
        )
        XCTAssertFalse(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.todesktop.230313mzl4w4u92"
            )
        )
    }
}
