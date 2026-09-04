import XCTest
@testable import Ping_Island

final class KiroIntegrationTests: XCTestCase {
    func testKiroManagedProfileUsesDedicatedV1HookFile() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "kiro-hooks"))

        XCTAssertEqual(profile.title, "Kiro")
        XCTAssertEqual(profile.installationKind, .kiroHookFile)
        XCTAssertEqual(profile.localAppBundleIdentifiers, ["dev.kiro.desktop"])
        XCTAssertTrue(profile.supportsEventSelection)
        XCTAssertEqual(profile.primaryConfigurationURL.path, NSHomeDirectory() + "/.kiro/hooks/ping-island.json")
        XCTAssertEqual(profile.events.map(\.name), ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"])
    }

    func testKiroRuntimeProfileUsesKiroLabel() throws {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: "kiro",
            explicitName: "Kiro",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Kiro",
            threadSource: "kiro-hooks",
            processName: nil
        )

        XCTAssertEqual(profile?.id, "kiro")
        XCTAssertEqual(profile?.displayName, "Kiro")
        XCTAssertEqual(profile?.defaultBundleIdentifier, "dev.kiro.desktop")

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "kiro",
            name: "Kiro",
            bundleIdentifier: "dev.kiro.desktop",
            origin: "cli",
            originator: "Kiro",
            threadSource: "kiro-hooks",
            terminalBundleIdentifier: "com.microsoft.VSCode"
        )
        XCTAssertTrue(clientInfo.prefersAppNavigation)

        let extensionProfile = try XCTUnwrap(ClientProfileRegistry.ideExtensionProfile(id: "kiro-extension"))
        XCTAssertEqual(extensionProfile.uriScheme, "kiro")
        XCTAssertEqual(extensionProfile.extensionRootRelativePaths, [".kiro/extensions"])
    }

    func testKiroHookFileUsesV1SchemaAndNonBlockingEvents() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "kiro-hooks"))
        XCTAssertEqual(HookInstallSelection.defaultSelection(for: profile).enabledEventNames, ["PostToolUse"])
        let configuration = HookInstaller.managedKiroHookConfiguration(for: profile)
        let hooks = try XCTUnwrap(configuration["hooks"] as? [[String: Any]])

        XCTAssertEqual(configuration["version"] as? String, "v1")
        XCTAssertEqual(hooks.map { $0["trigger"] as? String }, ["PostToolUse"])
        XCTAssertEqual(hooks[0]["matcher"] as? String, ".*")
        for hook in hooks {
            let action = try XCTUnwrap(hook["action"] as? [String: Any])
            XCTAssertEqual(action["type"] as? String, "command")
            XCTAssertTrue((action["command"] as? String)?.contains("--client-kind kiro") == true)
            XCTAssertTrue((action["command"] as? String)?.contains(">/dev/null 2>&1 || true") == true)
            XCTAssertEqual(hook["timeout"] as? Int, 10)
        }
    }
}
