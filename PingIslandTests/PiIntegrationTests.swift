import XCTest
@testable import Ping_Island

final class PiIntegrationTests: XCTestCase {
    func testPiManagedProfileUsesExtensionDirectoryInstallation() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "pi-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Pi Agent")
        XCTAssertEqual(profile?.installationKind, .pluginDirectory)
        XCTAssertEqual(profile?.brand, .pi)
        XCTAssertEqual(profile?.logoAssetName, "PiLogo")
        XCTAssertEqual(profile?.prefersBundledLogoOverAppIcon, true)
        XCTAssertEqual(profile?.primaryConfigurationURL.path, NSHomeDirectory() + "/.pi/agent/extensions/ping_island")
        XCTAssertEqual(
            profile?.bridgeExtraArguments,
            [
                "--client-kind", "pi",
                "--client-name", "Pi Agent",
                "--client-origin", "cli",
                "--client-originator", "Pi",
                "--thread-source", "pi-extension"
            ]
        )
        XCTAssertFalse(profile?.defaultEnabled ?? true)
    }

    func testPiGeneratedExtensionMapsLifecycleToolAndCompactionEvents() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "pi-hooks"))
        let files = HookInstaller.managedPluginDirectoryFiles(for: profile)
        let source = try XCTUnwrap(files["index.ts"])

        XCTAssertEqual(Set(files.keys), ["index.ts"])
        XCTAssertTrue(source.contains("Ping Island managed integration: pi-hooks"))
        XCTAssertTrue(source.contains("import type { ExtensionAPI }"))
        XCTAssertTrue(source.contains("pi.on(\"session_start\""))
        XCTAssertTrue(source.contains("hook_event_name: \"SessionStart\""))
        XCTAssertTrue(source.contains("pi.on(\"before_agent_start\""))
        XCTAssertTrue(source.contains("hook_event_name: \"UserPromptSubmit\""))
        XCTAssertTrue(source.contains("pi.on(\"tool_call\""))
        XCTAssertTrue(source.contains("hook_event_name: \"PreToolUse\""))
        XCTAssertTrue(source.contains("hook_event_name: \"PermissionRequest\""))
        XCTAssertTrue(source.contains("DANGEROUS_BASH_PATTERNS"))
        XCTAssertTrue(source.contains("return { block: true, reason: \"Blocked by Ping Island\" }"))
        XCTAssertTrue(source.contains("pi.on(\"tool_result\""))
        XCTAssertTrue(source.contains("hook_event_name: \"PostToolUse\""))
        XCTAssertTrue(source.contains("pi.on(\"agent_end\""))
        XCTAssertTrue(source.contains("hook_event_name: \"Stop\""))
        XCTAssertTrue(source.contains("last_assistant_message"))
        XCTAssertTrue(source.contains("pi.on(\"session_before_compact\""))
        XCTAssertTrue(source.contains("hook_event_name: \"PreCompact\""))
        XCTAssertTrue(source.contains("pi.on(\"session_compact\""))
        XCTAssertTrue(source.contains("hook_event_name: \"PostCompact\""))
        XCTAssertTrue(source.contains("session_id: `pi-${sessionId}`"))
        XCTAssertTrue(source.contains("_ppid: process.pid"))
        XCTAssertTrue(source.contains("_env: collectEnv()"))
        XCTAssertTrue(source.contains("_tty: tty"))
    }

    func testPiRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: "pi",
            explicitName: "Pi Agent",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Pi",
            threadSource: "pi-extension",
            processName: "pi"
        )

        XCTAssertEqual(profile?.id, "pi")
        XCTAssertEqual(profile?.brand, .pi)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "pi",
            name: "Pi Agent",
            origin: "cli",
            originator: "Pi",
            threadSource: "pi-extension"
        )

        XCTAssertEqual(clientInfo.brand, .pi)
        XCTAssertTrue(clientInfo.isPiClient)
        XCTAssertEqual(clientInfo.badgeLabel(for: .claude), "Pi Agent")
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .claude), .pi)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .claude), .pi)
        XCTAssertEqual(MascotClient.pi.defaultMascotKind, .pi)
        XCTAssertEqual(MascotClient.pi.subtitle, "Pi extension hooks 与终端云团")
        XCTAssertEqual(MascotKind.pi.subtitle, "π 轨道终端星核")
    }
}
