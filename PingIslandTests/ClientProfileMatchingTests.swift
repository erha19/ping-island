import XCTest
@testable import Ping_Island

final class ClientProfileMatchingTests: XCTestCase {
    func testUnrelatedHostsDoNotMatchAnIDEProfile() {
        let hosts: [(String?, String?)] = [
            (nil, nil),
            ("", ""),
            ("com.openai.codex", "Codex Desktop"),
            ("com.anthropic.claudefordesktop", "Claude Code"),
            ("com.googlecode.iterm2", "iTerm2"),
            ("com.mitchellh.ghostty", "Ghostty"),
            (nil, "Qwen Code"),
            (nil, "Kimi CLI"),
            ("com.example.terminal", "Example Terminal")
        ]

        for (bundle, name) in hosts {
            XCTAssertNil(
                ClientProfileRegistry.ideExtensionProfile(bundleIdentifier: bundle, appName: name),
                "Unrelated host: \(bundle ?? "nil") / \(name ?? "nil")"
            )
        }
    }

    func testNameOnlyIDERecognitionRequiresMatchingEvidence() {
        let hosts = [
            ("Cursor", "cursor-extension"),
            ("Visual Studio Code", "vscode-extension"),
            ("CodeBuddy", "codebuddy-extension"),
            ("WorkBuddy", "workbuddy-extension"),
            ("Qoder IDE", "qoder-extension"),
            ("Qoder CN IDE", "qoder-cn-extension")
        ]

        for (name, expectedProfileID) in hosts {
            XCTAssertEqual(
                ClientProfileRegistry.ideExtensionProfile(bundleIdentifier: nil, appName: name)?.id,
                expectedProfileID,
                name
            )
        }
    }

    func testClientsKeepTheirIdentityAfterResolvingQoderCN() {
        let qoderCN = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder-cn",
            name: "Qoder CN IDE",
            terminalBundleIdentifier: "com.aliyun.lingma.ide"
        ).normalizedForClaudeRouting()
        XCTAssertEqual(qoderCN.ideHostProfile?.id, "qoder-cn-extension")

        let clients: [(SessionProvider, SessionClientInfo, String)] = [
            (.codex, .codexApp(threadId: "test-codex-thread"), "Codex App"),
            (.claude, SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude-code",
                name: "Claude Code",
                terminalBundleIdentifier: "com.anthropic.claudefordesktop"
            ), "Claude Code"),
            (.claude, SessionClientInfo(
                kind: .claudeCode,
                name: "Claude Code",
                terminalBundleIdentifier: "com.googlecode.iterm2"
            ), "Claude Code"),
            (.claude, SessionClientInfo(
                kind: .custom,
                profileID: "qwen-code",
                name: "Qwen Code"
            ), "Qwen Code"),
            (.kimi, SessionClientInfo(
                kind: .custom,
                profileID: "kimi",
                name: "Kimi CLI"
            ), "Kimi CLI"),
            (.claude, SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli",
                terminalBundleIdentifier: "com.googlecode.iterm2"
            ), "Qoder CLI")
        ]

        for (provider, client, expectedLabel) in clients {
            let normalized = provider == .codex
                ? client.normalizedForCodexRouting()
                : client.normalizedForClaudeRouting()
            XCTAssertEqual(normalized.badgeLabel(for: provider), expectedLabel)
            XCTAssertNil(normalized.ideHostProfile, expectedLabel)
            XCTAssertNil(normalized.ideHostBadgeLabel(for: provider), expectedLabel)
        }
    }
}
