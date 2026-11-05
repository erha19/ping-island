import XCTest
@testable import Ping_Island

final class HookInstallerActivationTests: XCTestCase {
    func testDisablingMissingActivationConfigsDoesNotCreateAgentDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let openClaw = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "openclaw-hooks"))
        let openCode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "opencode-hooks"))
        let openClawURL = root.appendingPathComponent(".openclaw/openclaw.json")
        let openCodeURL = root.appendingPathComponent(".config/opencode/opencode.json")

        HookInstaller.setInternalHookEnabled(false, for: openClaw, customConfigURL: openClawURL)
        HookInstaller.setManagedPluginEnabled(false, for: openCode, customConfigURL: openCodeURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDisablingMissingActivationConfigsPreservesSkillsOnlyDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let openClaw = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "openclaw-hooks"))
        let openCode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "opencode-hooks"))
        let openClawDirectory = root.appendingPathComponent(".openclaw")
        let openCodeDirectory = root.appendingPathComponent(".config/opencode")

        for directory in [openClawDirectory, openCodeDirectory] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("skills"), withIntermediateDirectories: true
            )
        }
        HookInstaller.setInternalHookEnabled(
            false, for: openClaw, customConfigURL: openClawDirectory.appendingPathComponent("openclaw.json")
        )
        HookInstaller.setManagedPluginEnabled(
            false, for: openCode, customConfigURL: openCodeDirectory.appendingPathComponent("opencode.json")
        )

        for directory in [openClawDirectory, openCodeDirectory] {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["skills"])
        }
    }

    func testInternalHookCanStillBeEnabledAndDisabledWithoutLosingOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "openclaw-hooks"))
        let url = root.appendingPathComponent("openclaw.json")

        HookInstaller.setInternalHookEnabled(true, for: profile, customConfigURL: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertTrue(HookInstaller.isInternalHookEnabled(
            existingData: try Data(contentsOf: url), entryName: "ping-island-openclaw"
        ))
        json["userSetting"] = "preserve"
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        HookInstaller.setInternalHookEnabled(false, for: profile, customConfigURL: url)

        let data = try Data(contentsOf: url)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["userSetting"] as? String, "preserve")
        XCTAssertFalse(HookInstaller.isInternalHookEnabled(existingData: data, entryName: "ping-island-openclaw"))
    }

    func testPluginCanStillBeEnabledAndDisabledWithoutCreatingLegacyConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "opencode-hooks"))
        let url = root.appendingPathComponent("opencode.json")
        let pluginURL = root.appendingPathComponent("plugins/ping-island.js")

        HookInstaller.setManagedPluginEnabled(true, for: profile, customConfigURL: url, pluginURL: pluginURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["plugin"] as? [String], [pluginURL.absoluteString])
        json["userSetting"] = "preserve"
        json["plugin"] = [pluginURL.absoluteString, "other-plugin"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        HookInstaller.setManagedPluginEnabled(false, for: profile, customConfigURL: url, pluginURL: pluginURL)

        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["userSetting"] as? String, "preserve")
        XCTAssertEqual(json["plugin"] as? [String], ["other-plugin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
    }
}
