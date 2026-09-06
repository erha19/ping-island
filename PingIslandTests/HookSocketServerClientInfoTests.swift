import XCTest
@testable import Ping_Island

final class HookSocketServerClientInfoTests: XCTestCase {
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
