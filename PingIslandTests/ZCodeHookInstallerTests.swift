import XCTest
@testable import Ping_Island

final class ZCodeHookInstallerTests: XCTestCase {
    private var profile: ManagedHookClientProfile {
        get throws {
            try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
        }
    }

    private var islandCommand: String {
        get throws {
            let profile = try profile
            return HookInstaller.managedBridgeCommand(
                source: profile.bridgeSource,
                extraArguments: profile.bridgeExtraArguments,
                launcherPath: "/tmp/.ping-island/bin/ping-island-bridge",
                socketPath: "/tmp/.ping-island/run/agent-hook.sock"
            )
        }
    }

    func testUpdatedConfigurationDataInstallsUnderHooksEventsAndEnablesHooks() throws {
        let existingJSON = """
        {
          "plugins": { "dirs": ["/tmp/example"] },
          "hooks": {
            "enabled": false,
            "maxOutputBytes": 32768,
            "timeoutMs": 300000,
            "events": {
              "Stop": [
                {
                  "matcher": ".*",
                  "hooks": [
                    { "type": "command", "command": "/usr/bin/echo foreign" }
                  ]
                }
              ]
            }
          }
        }
        """.data(using: .utf8)

        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: try profile,
            customCommand: try islandCommand,
            installing: true
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)
        XCTAssertEqual(hooks["maxOutputBytes"] as? Int, 32768)
        XCTAssertEqual(hooks["timeoutMs"] as? Int, 300000)
        XCTAssertNotNil(object["plugins"])

        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"]) // must not flatten into hooks root

        let preToolUse = try XCTUnwrap(events["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.first?["matcher"] as? String, ".*")
        let preCommand = try XCTUnwrap((preToolUse.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(preCommand.contains("ping-island-bridge"))
        XCTAssertTrue(
            preCommand.contains("--client-kind zcode")
                || preCommand.contains("--client-kind 'zcode'")
                || preCommand.contains("'--client-kind' 'zcode'")
        )

        let stop = try XCTUnwrap(events["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2) // foreign + Island
        let stopCommands = stop.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        XCTAssertTrue(stopCommands.contains("/usr/bin/echo foreign"))
    }

    func testUpdatedConfigurationDataUninstallRemovesOnlyIslandEntries() throws {
        let islandCmd = try islandCommand
        let existingDict: [String: Any] = [
            "hooks": [
                "enabled": true,
                "timeoutMs": 300_000,
                "events": [
                    "Stop": [
                        [
                            "matcher": ".*",
                            "hooks": [
                                ["type": "command", "command": "/usr/bin/echo foreign"],
                            ],
                        ],
                        [
                            "matcher": ".*",
                            "hooks": [
                                ["type": "command", "command": islandCmd],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let existingJSON = try JSONSerialization.data(withJSONObject: existingDict)

        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: try profile,
            customCommand: try islandCommand,
            installing: false
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)
        XCTAssertEqual(hooks["timeoutMs"] as? Int, 300_000)

        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        let stop = try XCTUnwrap(events["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        let command = try XCTUnwrap((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertEqual(command, "/usr/bin/echo foreign")
    }

    func testUpdatedConfigurationDataReinstallDoesNotDuplicateIslandEntries() throws {
        let existingJSON = """
        {
          "hooks": {
            "enabled": true,
            "events": {}
          }
        }
        """.data(using: .utf8)

        let profile = try profile
        let islandCmd = try islandCommand

        let installedOnce = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: profile,
            customCommand: islandCmd,
            installing: true
        )
        let installedTwice = HookInstaller.updatedConfigurationData(
            existingData: installedOnce,
            profile: profile,
            customCommand: islandCmd,
            installing: true
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: installedTwice) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let events = try XCTUnwrap(hooks["events"] as? [String: Any])

        for eventName in profile.events.map(\.name) {
            let entries = try XCTUnwrap(events[eventName] as? [[String: Any]])
            let islandEntries = entries.filter { entry in
                guard let command = (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String else {
                    return false
                }
                return command.contains("ping-island-bridge")
            }
            XCTAssertEqual(
                islandEntries.count,
                1,
                "Expected exactly one Island entry for \(eventName) after reinstall"
            )
        }
    }

    func testZCodeManagedProfileUsesZCodeBrand() throws {
        let profile = try profile
        XCTAssertEqual(profile.brand, .zcode)
        XCTAssertEqual(profile.title, "ZCode")
    }

    func testZCodeRuntimeProfileResolvesBrandAndMascot() {
        let profile = ClientProfileRegistry.matchRuntimeProfile(
            provider: .claude,
            explicitKind: "zcode",
            explicitName: "ZCode",
            explicitBundleIdentifier: nil,
            terminalBundleIdentifier: nil,
            origin: "cli",
            originator: "ZCode",
            threadSource: nil,
            processName: "zcode"
        )

        XCTAssertEqual(profile?.id, "zcode")
        XCTAssertEqual(profile?.brand, .zcode)

        let clientInfo = SessionClientInfo(
            kind: .custom,
            profileID: "zcode",
            name: "ZCode",
            origin: "cli",
            originator: "ZCode"
        )

        XCTAssertEqual(clientInfo.brand, .zcode)
        XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .claude), .zcode)
        XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .claude), .zcode)
        XCTAssertEqual(MascotKind.zcode.subtitle, "紫色 Z 标记")
    }
}
