import XCTest
@testable import Ping_Island

final class AntigravityIntegrationTests: XCTestCase {
    func testManagedProfileUsesNativePluginDirectory() throws {
        let profile = try XCTUnwrap(
            ClientProfileRegistry.managedHookProfile(id: "antigravity-hooks")
        )

        XCTAssertEqual(profile.title, "Antigravity CLI")
        XCTAssertEqual(profile.installationKind, .pluginDirectory)
        XCTAssertEqual(profile.brand, .gemini)
        XCTAssertEqual(profile.logoAssetName, "GeminiLogo")
        XCTAssertTrue(profile.prefersBundledLogoOverAppIcon)
        XCTAssertEqual(
            profile.primaryConfigurationURL.path,
            NSHomeDirectory() + "/.gemini/antigravity-cli/plugins/ping-island"
        )
        XCTAssertEqual(
            Set(profile.events.map(\.name)),
            ["PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop"]
        )
    }

    func testGeneratedPluginUsesOfficialManifestAndNamespacedHookSchema() throws {
        let profile = try XCTUnwrap(
            ClientProfileRegistry.managedHookProfile(id: "antigravity-hooks")
        )
        let files = HookInstaller.managedPluginDirectoryFiles(for: profile)
        let manifestData = try XCTUnwrap(files["plugin.json"]?.data(using: .utf8))
        let hooksData = try XCTUnwrap(files["hooks.json"]?.data(using: .utf8))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let hooksRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: hooksData) as? [String: Any]
        )
        let hooks = try XCTUnwrap(hooksRoot["ping-island"] as? [String: Any])

        XCTAssertEqual(Set(files.keys), ["plugin.json", "hooks.json"])
        XCTAssertEqual(manifest["name"] as? String, "ping-island")
        XCTAssertEqual(
            manifest["$schema"] as? String,
            "https://antigravity.google/schemas/v1/plugin.json"
        )
        XCTAssertTrue(
            (manifest["description"] as? String)?
                .contains("Ping Island managed integration: antigravity-hooks") == true
        )

        let preToolEntries = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let preToolEntry = try XCTUnwrap(preToolEntries.first)
        XCTAssertEqual(preToolEntry["matcher"] as? String, ".*")
        let preToolCommands = try XCTUnwrap(preToolEntry["hooks"] as? [[String: Any]])
        let preToolCommand = try XCTUnwrap(preToolCommands.first?["command"] as? String)
        XCTAssertTrue(preToolCommand.contains("--client-kind antigravity"))
        XCTAssertTrue(preToolCommand.contains("--event PreToolUse"))

        let invocationEntries = try XCTUnwrap(hooks["PreInvocation"] as? [[String: Any]])
        let invocationCommand = try XCTUnwrap(invocationEntries.first?["command"] as? String)
        XCTAssertTrue(invocationCommand.contains("--event PreInvocation"))
        XCTAssertNil(invocationEntries.first?["hooks"])
    }

    func testRemotePluginUsesRemoteBridgeAndSocket() throws {
        let profile = try XCTUnwrap(
            ClientProfileRegistry.managedHookProfile(id: "antigravity-hooks")
        )
        let files = HookInstaller.managedPluginDirectoryFiles(
            for: profile,
            bridgeArguments: [
                "/root/.ping-island/bin/ping-island-bridge",
                "--source", "gemini",
                "--client-kind", "antigravity"
            ],
            bridgeEnvironment: [
                "ISLAND_SOCKET_PATH": "/root/.ping-island/run/agent-hook.sock"
            ]
        )
        let hooks = try XCTUnwrap(files["hooks.json"])

        XCTAssertTrue(hooks.contains("/root/.ping-island/bin/ping-island-bridge"))
        XCTAssertTrue(hooks.contains("ISLAND_SOCKET_PATH="))
        XCTAssertTrue(hooks.contains("/root/.ping-island/run/agent-hook.sock"))
        XCTAssertFalse(hooks.contains(NSHomeDirectory() + "/.ping-island/bin"))
    }

    func testRuntimeProfileKeepsAntigravityIdentityWithGeminiMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .gemini,
            explicitKind: "agy",
            explicitName: "Antigravity CLI",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "Antigravity CLI",
            threadSource: "antigravity-hooks",
            processName: "agy"
        )

        XCTAssertEqual(profile?.id, "antigravity")
        XCTAssertEqual(profile?.displayName, "Antigravity CLI")
        XCTAssertEqual(profile?.brand, .gemini)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "antigravity",
            name: "Antigravity CLI",
            origin: "cli",
            originator: "Antigravity CLI",
            threadSource: "antigravity-hooks"
        )

        XCTAssertTrue(clientInfo.isGeminiClient)
        XCTAssertTrue(clientInfo.prefersHookMessageAsLastMessageFallback)
        XCTAssertEqual(clientInfo.badgeLabel(for: .gemini), "Antigravity CLI")
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .gemini), .gemini)
    }
}
