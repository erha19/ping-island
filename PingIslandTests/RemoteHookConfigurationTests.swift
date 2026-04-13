import XCTest
@testable import Ping_Island

final class RemoteHookConfigurationTests: XCTestCase {
    func testRemoteBootstrapPrepareCommandStopsRunningAgentBeforeReplacingBridge() {
        let command = RemoteConnectorManager.remoteBootstrapPrepareCommand(
            installRoot: "/root/.ping-island",
            controlSocketPath: "/root/.ping-island/run/agent-control.sock",
            hookSocketPath: "/root/.ping-island/run/agent-hook.sock",
            configDirectoryPaths: ["/root/.codex", "/root/.qoder"]
        )

        XCTAssertTrue(command.contains("mkdir -p "))
        XCTAssertTrue(command.contains("pkill -f "))
        XCTAssertTrue(command.contains("PingIslandBridge"))
        XCTAssertTrue(command.contains("rm -f "))
        XCTAssertTrue(command.contains("PingIslandBridge.tmp"))
    }

    func testRemoteBootstrapInstallCommandPromotesStagedBridgeAtomically() {
        let command = RemoteConnectorManager.remoteBootstrapInstallCommand(
            installRoot: "/root/.ping-island",
            stagedBridgePath: "/root/.ping-island/bin/PingIslandBridge.tmp"
        )

        XCTAssertTrue(command.contains("mv -f '/root/.ping-island/bin/PingIslandBridge.tmp' '/root/.ping-island/bin/PingIslandBridge'"))
        XCTAssertTrue(command.contains("chmod 755 '/root/.ping-island/bin/PingIslandBridge' '/root/.ping-island/bin/ping-island-bridge'"))
    }

    func testRemoteManagedHookProfilesIncludeSupportedCliIntegrations() {
        let profileIDs = Set(RemoteConnectorManager.remoteManagedHookProfiles().map(\.id))

        XCTAssertEqual(profileIDs, [
            "claude-hooks",
            "codex-hooks",
            "qwen-code-hooks",
            "openclaw-hooks",
            "qoder-hooks",
            "qoderwork-hooks",
        ])
    }

    func testRemoteManagedHookConfigDirectoryPathsResolveUnderRemoteHome() {
        let directories = RemoteConnectorManager.remoteManagedHookConfigDirectoryPaths(
            homeDirectory: "/root",
            profiles: RemoteConnectorManager.remoteManagedHookProfiles()
        )

        XCTAssertTrue(directories.contains("/root/.claude"))
        XCTAssertTrue(directories.contains("/root/.codex"))
        XCTAssertTrue(directories.contains("/root/.qwen"))
        XCTAssertTrue(directories.contains("/root/.openclaw"))
        XCTAssertTrue(directories.contains("/root/.openclaw/hooks"))
        XCTAssertTrue(directories.contains("/root/.openclaw/hooks/ping-island-openclaw"))
        XCTAssertTrue(directories.contains("/root/.qoder"))
        XCTAssertTrue(directories.contains("/root/.qoderwork"))
    }

    func testRemoteConfigurationPathResolvesRelativeHomePaths() {
        XCTAssertEqual(
            RemoteConnectorManager.remoteConfigurationPath(
                relativePath: ".codex/hooks.json",
                homeDirectory: "/root"
            ),
            "/root/.codex/hooks.json"
        )
    }

    func testShouldBootstrapRemoteAgentForFreshEndpoint() {
        let endpoint = RemoteEndpoint(
            displayName: "Fresh",
            sshTarget: "dev@example"
        )

        XCTAssertTrue(
            RemoteConnectorManager.shouldBootstrapRemoteAgent(
                endpoint: endpoint,
                forceBootstrap: false
            )
        )
    }

    func testShouldReuseRemoteAgentAfterSuccessfulConnection() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example",
            agentVersion: "1.2.3",
            lastConnectedAt: Date()
        )

        XCTAssertFalse(
            RemoteConnectorManager.shouldBootstrapRemoteAgent(
                endpoint: endpoint,
                forceBootstrap: false
            )
        )
    }

    func testShouldBootstrapRemoteAgentWhenForced() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example",
            agentVersion: "1.2.3",
            lastConnectedAt: Date()
        )

        XCTAssertTrue(
            RemoteConnectorManager.shouldBootstrapRemoteAgent(
                endpoint: endpoint,
                forceBootstrap: true
            )
        )
    }

    func testResolvedRemoteHostHintPrefersPayloadHost() {
        let endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example"
        )

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: "remote-box",
                endpoint: endpoint
            ),
            "remote-box"
        )
    }

    func testResolvedRemoteHostHintFallsBackToDetectedHostnameThenSSHTarget() {
        var detectedEndpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@example"
        )
        detectedEndpoint.detectedHostname = "detected-box"

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: nil,
                endpoint: detectedEndpoint
            ),
            "detected-box"
        )

        let targetOnlyEndpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@box.example.com:2222"
        )
        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: nil,
                endpoint: targetOnlyEndpoint
            ),
            "box.example.com"
        )
    }

    func testResolvedRemoteHostHintPrefersDetectedHostnameOverPayloadIP() {
        var endpoint = RemoteEndpoint(
            displayName: "Known Host",
            sshTarget: "dev@172.25.145.237"
        )
        endpoint.detectedHostname = "devbox"

        XCTAssertEqual(
            RemoteConnectorManager.resolvedRemoteHostHint(
                payloadRemoteHost: "172.25.145.237",
                endpoint: endpoint
            ),
            "devbox"
        )
    }

    func testManagedConfigurationDataInstallsClaudeHooksWithoutRemovingExistingEntries() throws {
        let existingJSON = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/echo existing"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "claude-hooks"))
        let command = HookInstaller.managedBridgeCommand(
            source: profile.bridgeSource,
            extraArguments: profile.bridgeExtraArguments,
            launcherPath: "/remote/bin/ping-island-bridge",
            socketPath: "/remote/run/agent-hook.sock"
        )

        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: profile,
            customCommand: command,
            installing: true
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])

        XCTAssertEqual(promptEntries.count, 2)
    }

    func testManagedConfigurationDataRemovesLocalOnlyCommandsForRemoteInstall() throws {
        let existingJSON = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/Users/wudanwu/.claude/hooks/peon-ping/scripts/hook-handle-use.sh"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/echo keep"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "claude-hooks"))
        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: profile,
            customCommand: "ISLAND_SOCKET_PATH='/root/.ping-island/run/agent-hook.sock' '/root/.ping-island/bin/ping-island-bridge' --source claude",
            installing: true,
            removingCommandPrefixes: ["/Users/"]
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        let commands = promptEntries
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertFalse(commands.contains { $0.contains("/Users/wudanwu/.claude/hooks/peon-ping") })
        XCTAssertTrue(commands.contains("/usr/bin/echo keep"))
        XCTAssertTrue(commands.contains { $0.contains("/root/.ping-island/bin/ping-island-bridge") })
    }

    func testManagedConfigurationDataRemovesIslandManagedEntriesWhenUninstalling() throws {
        let existingJSON = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/echo keep"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "ISLAND_SOCKET_PATH='/remote/run/agent-hook.sock' '/home/test/.ping-island/bin/ping-island-bridge' --source claude"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "claude-hooks"))
        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: profile,
            customCommand: "",
            installing: false
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let promptEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])

        XCTAssertEqual(promptEntries.count, 1)
    }

    func testOpenClawInternalHookConfigurationDataEnablesManagedEntry() throws {
        let data = HookInstaller.updatedInternalHookConfigurationData(
            existingData: nil,
            entryName: "ping-island-openclaw",
            installing: true
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let internalHooks = try XCTUnwrap(hooks["internal"] as? [String: Any])
        let enabled = try XCTUnwrap(internalHooks["enabled"] as? Bool)
        let entries = try XCTUnwrap(internalHooks["entries"] as? [String: Any])
        let entry = try XCTUnwrap(entries["ping-island-openclaw"] as? [String: Any])

        XCTAssertTrue(enabled)
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertTrue(
            HookInstaller.isInternalHookEnabled(
                existingData: data,
                entryName: "ping-island-openclaw"
            )
        )
    }

    func testOpenClawInternalHookConfigurationDataDisablesManagedEntry() throws {
        let existingJSON = """
        {
          "hooks": {
            "internal": {
              "enabled": true,
              "entries": {
                "ping-island-openclaw": {
                  "enabled": true,
                  "env": {
                    "PING_ISLAND_DEBUG": "1"
                  }
                }
              }
            }
          }
        }
        """.data(using: .utf8)

        let data = HookInstaller.updatedInternalHookConfigurationData(
            existingData: existingJSON,
            entryName: "ping-island-openclaw",
            installing: false
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let internalHooks = try XCTUnwrap(hooks["internal"] as? [String: Any])
        let entries = try XCTUnwrap(internalHooks["entries"] as? [String: Any])
        let entry = try XCTUnwrap(entries["ping-island-openclaw"] as? [String: Any])
        let env = try XCTUnwrap(entry["env"] as? [String: String])

        XCTAssertEqual(entry["enabled"] as? Bool, false)
        XCTAssertEqual(env["PING_ISLAND_DEBUG"], "1")
        XCTAssertFalse(
            HookInstaller.isInternalHookEnabled(
                existingData: data,
                entryName: "ping-island-openclaw"
            )
        )
    }

    func testOpenClawRemoteBridgeArgumentsAndEnvironmentUseRemoteInstallRootAndSocket() throws {
        let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "openclaw-hooks"))
        let arguments = RemoteConnectorManager.remoteManagedBridgeArguments(
            for: profile,
            installRoot: "/root/.ping-island"
        )
        let environment = RemoteConnectorManager.remoteManagedBridgeEnvironment(
            hookSocketPath: "/root/.ping-island/run/agent-hook.sock"
        )

        XCTAssertEqual(arguments.prefix(3), [
            "/root/.ping-island/bin/ping-island-bridge",
            "--source",
            "claude",
        ])
        XCTAssertTrue(arguments.contains("--client-kind"))
        XCTAssertTrue(arguments.contains("openclaw"))
        XCTAssertEqual(
            environment,
            ["ISLAND_SOCKET_PATH": "/root/.ping-island/run/agent-hook.sock"]
        )
    }
}
