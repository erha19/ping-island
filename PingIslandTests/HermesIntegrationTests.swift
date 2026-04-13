import XCTest
@testable import Ping_Island

final class HermesIntegrationTests: XCTestCase {
    func testHermesManagedProfileUsesPluginDirectoryInstallation() {
        let profile = ClientProfileRegistry.managedHookProfile(id: "hermes-hooks")

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.title, "Hermes Agent")
        XCTAssertEqual(profile?.installationKind, .pluginDirectory)
        XCTAssertEqual(profile?.brand, .hermes)
        XCTAssertNil(profile?.activationConfigurationURL)
        XCTAssertEqual(profile?.primaryConfigurationURL.path, NSHomeDirectory() + "/.hermes/plugins/ping_island")
        XCTAssertTrue(profile?.reinstallDescriptionFormat.contains("插件目录") == true)
    }

    func testHermesManagedPluginDirectoryIncludesObservedHookRegistrations() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "hermes-hooks"))
        let files = HookInstaller.managedPluginDirectoryFiles(for: profile)
        let pluginYAML = try XCTUnwrap(files["plugin.yaml"])
        let pluginSource = try XCTUnwrap(files["__init__.py"])

        XCTAssertTrue(pluginYAML.contains("name: ping-island"))
        XCTAssertTrue(pluginYAML.contains("hooks: true"))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"on_session_start\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"pre_llm_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"pre_tool_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"post_tool_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"post_llm_call\""))
        XCTAssertTrue(pluginSource.contains("ctx.register_hook(\"on_session_end\""))
        XCTAssertTrue(pluginSource.contains("BRIDGE_ARGS ="))
        XCTAssertTrue(pluginSource.contains("hook_event_name=\"UserPromptSubmit\""))
        XCTAssertTrue(pluginSource.contains("event_name = \"SessionEnd\" if completed else \"Stop\""))
        XCTAssertTrue(pluginSource.contains("\"hermes-plugin\""))
    }

    func testHermesRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: "hermes-agent",
            explicitName: "Hermes Agent",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin",
            processName: "hermes"
        )

        XCTAssertEqual(profile?.id, "hermes")
        XCTAssertEqual(profile?.brand, .hermes)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "hermes",
            name: "Hermes Agent",
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin"
        )

        XCTAssertEqual(clientInfo.brand, .hermes)
        XCTAssertTrue(clientInfo.isHermesClient)
        XCTAssertTrue(clientInfo.prefersHookMessageAsLastMessageFallback)
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .claude), .hermes)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .claude), .hermes)
    }

    func testHermesLastMessageFallsBackToHookMessageForPopupPreview() {
        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "hermes",
            name: "Hermes Agent",
            origin: "cli",
            originator: "Hermes",
            threadSource: "hermes-plugin"
        )
        let session = SessionState(
            sessionId: "hermes-end",
            cwd: "/tmp/project",
            provider: .claude,
            clientInfo: clientInfo,
            latestHookMessage: "Hermes finished the response and queued the next action summary.",
            phase: .ended
        )

        XCTAssertEqual(
            session.lastMessage,
            "Hermes finished the response and queued the next action summary."
        )
    }
}
