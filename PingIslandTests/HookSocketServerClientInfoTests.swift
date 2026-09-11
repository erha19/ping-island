import XCTest
@testable import Ping_Island

final class HookSocketServerClientInfoTests: XCTestCase {
    func testCodexDesktopSourceIgnoresBareQoderHostHints() throws {
        for host in ["com.qoder.ide", "com.aliyun.lingma.ide"] {
            let event = try decodeCodexEvent(
                terminalContext: ["terminalBundleID": host, "ideBundleID": host, "ideName": "Qoder CN IDE"],
                metadata: ["client_origin": "desktop", "client_originator": "Codex Desktop", "thread_source": "vscode"]
            )
            XCTAssertEqual(event.clientInfo.kind, .codexApp)
            XCTAssertEqual(event.clientInfo.profileID, "codex-app")
            XCTAssertEqual(event.clientInfo.bundleIdentifier, "com.openai.codex")
            XCTAssertEqual(event.clientInfo.launchURL, "codex://threads/test-codex-identity")
            XCTAssertNil(event.clientInfo.ideHostBadgeLabel(for: .codex))
        }
    }

    func testCodexDesktopHintsPreserveActualQoderTerminal() throws {
        for context in [
            ["terminalProgram": "vscode", "tty": "/dev/ttys004"],
            ["terminalSessionID": "terminal-123"],
            ["tmuxSession": "work", "tmuxPane": "%1"]
        ] {
            let event = try decodeCodexEvent(
                terminalContext: context.merging([
                    "terminalBundleID": "com.aliyun.lingma.ide",
                    "ideBundleID": "com.aliyun.lingma.ide", "ideName": "Qoder CN IDE"
                ]) { first, _ in first },
                metadata: ["client_kind": "codex-app", "client_origin": "desktop", "client_originator": "Codex Desktop"]
            )
            XCTAssertEqual(event.clientInfo.kind, .codexCLI)
            XCTAssertEqual(event.clientInfo.profileID, "codex-cli")
            XCTAssertEqual(event.clientInfo.terminalBundleIdentifier, "com.aliyun.lingma.ide")
            XCTAssertEqual(event.clientInfo.ideHostBadgeLabel(for: .codex), "Qoder CN IDE 终端")
        }
    }

    private func decodeCodexEvent(terminalContext: [String: String], metadata: [String: String]) throws -> HookEvent {
        let envelope: [String: Any] = [
            "id": UUID().uuidString, "provider": "codex", "eventType": "UserPromptSubmit",
            "sessionKey": "codex:test-codex-identity", "cwd": "/tmp/project",
            "terminalContext": terminalContext, "metadata": metadata, "expectsResponse": false
        ]
        return try HookSocketServer.decodeHookEvent(from: JSONSerialization.data(withJSONObject: envelope))
    }

    func testClaudeHookKeepsClientIdentityInsideQoderIDETerminals() throws {
        for (hostName, hostBundle) in [
            ("Qoder IDE", "com.qoder.ide"),
            ("Qoder CN IDE", "com.aliyun.lingma.ide")
        ] {
            let event = try decodeClientEvent(
                hostName: hostName,
                hostBundle: hostBundle,
                metadata: ["client_originator": hostName, "source_process_name": "/opt/claude/bin/claude"]
            )

            XCTAssertEqual(event.clientInfo.kind, .claudeCode, hostName)
            XCTAssertEqual(event.clientInfo.profileID, "claude-code", hostName)
            XCTAssertEqual(event.clientInfo.badgeLabel(for: .claude), "Claude Code", hostName)
            XCTAssertEqual(event.clientInfo.ideHostBadgeLabel(for: .claude), "\(hostName) 终端")
            XCTAssertFalse(event.clientInfo.isQoderNotifyOnlyIDEClient, hostName)
        }
    }

    func testExplicitQoderCNHookKeepsItsClientIdentity() throws {
        let event = try decodeClientEvent(
            hostName: "Qoder CN IDE",
            hostBundle: "com.aliyun.lingma.ide",
            metadata: [
                "client_kind": "qoder-cn",
                "client_name": "Qoder CN IDE",
                "client_originator": "Qoder CN IDE"
            ]
        )

        XCTAssertEqual(event.clientInfo.profileID, "qoder-cn")
        XCTAssertEqual(event.clientInfo.badgeLabel(for: .claude), "Qoder CN IDE")
        XCTAssertTrue(event.clientInfo.isQoderNotifyOnlyIDEClient)
    }

    func testClaudeHookWithoutProcessHintReplacesCachedQoderClientIdentity() throws {
        let event = try decodeClientEvent(
            hostName: "Qoder CN IDE",
            hostBundle: "com.aliyun.lingma.ide",
            metadata: ["client_originator": "Qoder CN IDE"]
        )
        let cached = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder-cn",
            name: "Qoder CN IDE",
            terminalBundleIdentifier: "com.aliyun.lingma.ide"
        )
        let restored = cached.merged(with: event.clientInfo).normalizedForClaudeRouting()

        XCTAssertEqual(restored.kind, .claudeCode)
        XCTAssertEqual(restored.profileID, "claude-code")
        XCTAssertEqual(restored.badgeLabel(for: .claude), "Claude Code")
        XCTAssertFalse(restored.isQoderNotifyOnlyIDEClient)
    }

    func testExplicitClaudeNameWinsOverQoderCNHostBundle() throws {
        let event = try decodeClientEvent(
            hostName: "Qoder CN IDE",
            hostBundle: "com.aliyun.lingma.ide",
            metadata: ["client_name": "Claude Code", "client_originator": "Qoder CN IDE"]
        )

        XCTAssertEqual(event.clientInfo.kind, .claudeCode)
        XCTAssertEqual(event.clientInfo.profileID, "claude-code")
        XCTAssertEqual(event.clientInfo.badgeLabel(for: .claude), "Claude Code")
    }

    func testQoderCLIProcessIgnoresIDEHintForExplicitCLIProfile() {
        XCTAssertEqual(
            HookSocketServer.qoderCLIProfileSkipDecision(
                clientKind: "qoder-cli",
                sourceProcessName: "qodercli"
            ),
            false
        )
    }

    func testQoderCLIProcessSkipsDuplicateDesktopProfile() {
        XCTAssertEqual(
            HookSocketServer.qoderCLIProfileSkipDecision(
                clientKind: "qoder",
                sourceProcessName: "qodercli"
            ),
            true
        )
    }

    func testTerminalHostBundlePrefersStandaloneTerminalOverIDEHint() {
        XCTAssertEqual(
            HookSocketServer.resolvedTerminalHostBundleIdentifier(
                terminalBundleID: "com.googlecode.iterm2",
                ideBundleID: "com.qoder.ide"
            ),
            "com.googlecode.iterm2"
        )
    }

    func testTerminalHostBundleKeepsIDEWhenTerminalIsIDEHost() {
        XCTAssertEqual(
            HookSocketServer.resolvedTerminalHostBundleIdentifier(
                terminalBundleID: "com.qoder.ide",
                ideBundleID: "com.qoder.ide"
            ),
            "com.qoder.ide"
        )
    }

    func testCodexITermContextInfersCLIOverDesktopHints() {
        let kind = HookSocketServer.inferredCodexClientKind(
            explicitKind: "codex-app",
            explicitName: "Codex App",
            explicitBundleID: nil,
            hasExplicitNonTerminalBundle: false,
            terminalTTY: "/dev/ttys001",
            terminalProgram: "iTerm.app",
            terminalBundleID: "com.googlecode.iterm2",
            ideBundleID: nil,
            matchedProfileKind: .codexApp
        )

        XCTAssertEqual(kind, .codexCLI)
    }

    func testCodexAppBundleWithoutTerminalContextStaysApp() {
        let kind = HookSocketServer.inferredCodexClientKind(
            explicitKind: "desktop",
            explicitName: "Codex App",
            explicitBundleID: "com.openai.codex",
            hasExplicitNonTerminalBundle: false,
            terminalTTY: nil,
            terminalProgram: nil,
            terminalBundleID: nil,
            ideBundleID: nil,
            matchedProfileKind: .codexApp
        )

        XCTAssertEqual(kind, .codexApp)
    }

    func testCodexCLIKindStillWinsWithoutTerminalContext() {
        let kind = HookSocketServer.inferredCodexClientKind(
            explicitKind: "codex-cli",
            explicitName: "Codex",
            explicitBundleID: nil,
            hasExplicitNonTerminalBundle: false,
            terminalTTY: nil,
            terminalProgram: nil,
            terminalBundleID: nil,
            ideBundleID: nil,
            matchedProfileKind: .codexApp
        )

        XCTAssertEqual(kind, .codexCLI)
    }

    private func decodeClientEvent(
        hostName: String,
        hostBundle: String,
        metadata: [String: String]
    ) throws -> HookEvent {
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "provider": "claude",
            "eventType": "UserPromptSubmit",
            "sessionKey": "claude:test-client-identity",
            "cwd": "/tmp/project",
            "terminalContext": [
                "terminalProgram": "vscode",
                "terminalBundleID": hostBundle,
                "ideBundleID": hostBundle,
                "ideName": hostName
            ],
            "metadata": metadata,
            "expectsResponse": false
        ]
        return try HookSocketServer.decodeHookEvent(from: JSONSerialization.data(withJSONObject: envelope))
    }
}
