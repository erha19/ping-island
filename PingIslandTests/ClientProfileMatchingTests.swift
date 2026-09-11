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

    func testCanonicalCodexSnapshotClearsRestoredQoderTerminalRouting() {
        let sessionId = "codex-thread-with-stale-host"
        let repaired = SessionStore.normalizedCodexClientInfo(
            restored: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                originator: "Qoder CN IDE",
                terminalBundleIdentifier: "com.aliyun.lingma.ide",
                terminalProgram: "vscode"
            ),
            incoming: .codexApp(threadId: sessionId),
            sessionId: sessionId
        )

        XCTAssertEqual(repaired.profileID, "codex-app")
        XCTAssertEqual(repaired.name, "Codex App")
        XCTAssertEqual(repaired.bundleIdentifier, "com.openai.codex")
        XCTAssertNil(repaired.originator)
        XCTAssertNil(repaired.terminalBundleIdentifier)
        XCTAssertNil(repaired.ideHostProfile)
        XCTAssertNil(repaired.ideHostBadgeLabel(for: .codex))
    }

    func testCanonicalDesktopRepairsContaminatedCLIAndKeepsUnrelatedMetadata() throws {
        let sessionId = "polluted-codex-desktop"
        for host in ["com.qoder.ide", "com.aliyun.lingma.ide"] {
            let cached = SessionClientInfo(
                kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI",
                launchURL: "qoder-cn://file/tmp/project", origin: "cli", originator: "Qoder CN IDE",
                threadSource: "vscode", transport: "ssh-remote", remoteHost: "devbox",
                sessionFilePath: "/tmp/codex/rollout.jsonl", terminalBundleIdentifier: host
            )
            let repaired = SessionStore.normalizedCodexClientInfo(
                restored: cached, incoming: .codexApp(threadId: sessionId), sessionId: sessionId
            )
            XCTAssertEqual(repaired.kind, .codexApp)
            XCTAssertEqual(repaired.profileID, "codex-app")
            XCTAssertEqual(repaired.name, "Codex App")
            XCTAssertEqual(repaired.launchURL, "codex://threads/\(sessionId)")
            XCTAssertNil(repaired.terminalBundleIdentifier)
            XCTAssertNil(repaired.originator)
            XCTAssertNil(repaired.ideHostProfile)
            XCTAssertEqual(repaired.remoteHost, "devbox")
            XCTAssertEqual(repaired.sessionFilePath, "/tmp/codex/rollout.jsonl")
            let reloaded = try JSONDecoder().decode(SessionClientInfo.self, from: JSONEncoder().encode(repaired))
            XCTAssertEqual(reloaded.normalizedForCodexRouting(sessionId: sessionId), repaired)
        }
    }

    func testConfirmedDesktopCacheRepairsBareQoderHostWithoutNewSnapshot() {
        let cached = SessionClientInfo(
            kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI",
            launchURL: "qoder-cn://file/tmp/project", origin: "desktop", originator: "Codex Desktop",
            threadSource: "vscode", terminalBundleIdentifier: "com.aliyun.lingma.ide"
        )
        let repaired = cached.normalizedForCodexRouting(sessionId: "desktop-cache")
        XCTAssertEqual(repaired.kind, .codexApp)
        XCTAssertEqual(repaired.profileID, "codex-app")
        XCTAssertEqual(repaired.bundleIdentifier, "com.openai.codex")
        XCTAssertEqual(repaired.launchURL, "codex://threads/desktop-cache")
        XCTAssertNil(repaired.terminalBundleIdentifier)
        XCTAssertNil(repaired.ideHostProfile)

        let association = PersistedSessionAssociation(session: SessionState(
            sessionId: "desktop-cache", cwd: "/tmp/project", projectName: "project", provider: .codex,
            clientInfo: cached, sessionName: "User work"
        ))
        let migrated = SessionAssociationStore.normalizedAssociations(["codex:desktop-cache": association])
        XCTAssertEqual(migrated["codex:desktop-cache"]?.clientInfo, repaired)
        XCTAssertEqual(migrated["codex:desktop-cache"]?.sessionName, "User work")
        XCTAssertEqual(SessionAssociationStore.normalizedAssociations(migrated), migrated)
    }

    func testExplicitRoutingReplacementClearsFieldsWhilePartialUpdatesKeepThem() throws {
        let cached = SessionClientInfo(
            kind: .codexCLI, launchURL: "qoder-cn://file/tmp/project", originator: "Qoder CN IDE",
            sessionFilePath: "/tmp/rollout.jsonl", terminalBundleIdentifier: "com.aliyun.lingma.ide",
            terminalProgram: "vscode", terminalTTY: "/dev/ttys004", terminalSessionIdentifier: "terminal-1"
        )
        let desktop = SessionClientInfo.codexApp(threadId: "repair")
        XCTAssertEqual(cached.merged(with: desktop).terminalSessionIdentifier, "terminal-1")
        let replaced = cached.merged(with: desktop, replacingRouting: true)
        XCTAssertNil(replaced.originator)
        XCTAssertNil(replaced.terminalBundleIdentifier)
        XCTAssertNil(replaced.terminalProgram)
        XCTAssertNil(replaced.terminalTTY)
        XCTAssertNil(replaced.terminalSessionIdentifier)
        XCTAssertEqual(replaced.sessionFilePath, "/tmp/rollout.jsonl")
        let legacy = try JSONDecoder().decode(SessionClientInfo.self, from: Data(#"{"kind":"codexCLI","origin":"cli"}"#.utf8))
        XCTAssertNil(legacy.terminalTTY)
    }

    func testDesktopSnapshotPreservesRealQoderCLIRouting() {
        let cached = SessionClientInfo(
            kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI",
            launchURL: "qoder-cn://file/tmp/project", origin: "cli",
            terminalBundleIdentifier: "com.aliyun.lingma.ide", terminalProgram: "vscode",
            terminalSessionIdentifier: "terminal-123"
        )
        let merged = SessionStore.normalizedCodexClientInfo(
            restored: cached, incoming: .codexApp(threadId: "real-cli"), sessionId: "real-cli"
        )
        XCTAssertEqual(merged.kind, .codexCLI)
        XCTAssertEqual(merged.profileID, "codex-cli")
        XCTAssertEqual(merged.terminalSessionIdentifier, "terminal-123")
        XCTAssertEqual(merged.ideHostBadgeLabel(for: .codex), "Qoder CN IDE 终端")
        XCTAssertFalse(merged.prefersAppNavigation)
    }

    func testLegacyAppClassificationWithRealTerminalEvidenceMigratesToCLI() {
        for host in ["com.aliyun.lingma.ide", "com.mitchellh.ghostty"] {
            let cached = SessionClientInfo(
                kind: .codexApp, profileID: "codex-app", name: "Codex App",
                bundleIdentifier: "com.openai.codex", launchURL: "codex://threads/legacy-cli", origin: "desktop",
                terminalBundleIdentifier: host, terminalTTY: "/dev/ttys007", terminalSessionIdentifier: "terminal-7"
            )
            let migrated = cached.normalizedForCodexRouting(sessionId: "legacy-cli")
            XCTAssertEqual(migrated.kind, .codexCLI)
            XCTAssertEqual(migrated.profileID, "codex-cli")
            XCTAssertNil(migrated.bundleIdentifier)
            XCTAssertNil(migrated.launchURL)
            let updated = SessionStore.normalizedCodexClientInfo(
                restored: migrated, incoming: .codexApp(threadId: "legacy-cli"), sessionId: "legacy-cli"
            )
            XCTAssertEqual(updated.kind, .codexCLI)
            XCTAssertEqual(updated.terminalTTY, "/dev/ttys007")
            XCTAssertEqual(updated.terminalBundleIdentifier, host)
        }
    }

    func testDesktopOriginatorRepairsInferredCLIOriginButPreservesExplicitCLISource() {
        var cached = SessionClientInfo(
            kind: .codexCLI, profileID: "codex-cli", name: "Codex CLI",
            launchURL: "qoder-cn://file/tmp/project", origin: "cli", originator: "Codex Desktop",
            threadSource: "vscode", terminalBundleIdentifier: "com.aliyun.lingma.ide"
        )
        let repaired = cached.normalizedForCodexRouting(sessionId: "desktop-originator")
        XCTAssertEqual(repaired.kind, .codexApp)
        XCTAssertEqual(repaired.origin, "desktop")
        XCTAssertNil(repaired.terminalBundleIdentifier)
        XCTAssertEqual(repaired.launchURL, "codex://threads/desktop-originator")

        cached.threadSource = "cli"
        XCTAssertEqual(cached.normalizedForCodexRouting().kind, .codexCLI)
        cached.threadSource = "vscode"
        cached.terminalTTY = "/dev/ttys003"
        XCTAssertEqual(cached.normalizedForCodexRouting().kind, .codexCLI)
    }

    func testCodexAppServerSnapshotPreservesUnrelatedRestoredTerminalRouting() {
        let sessionId = "codex-cli-thread"
        let restored = SessionClientInfo(
            kind: .codexCLI,
            profileID: "codex-cli",
            name: "Codex CLI",
            origin: "cli",
            originator: "Ghostty",
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            terminalProgram: "ghostty",
            terminalSessionIdentifier: "terminal-session"
        )
        let merged = SessionStore.normalizedCodexClientInfo(
            restored: restored,
            incoming: .codexApp(threadId: sessionId),
            sessionId: sessionId
        )

        XCTAssertEqual(merged.kind, .codexCLI)
        XCTAssertEqual(merged.profileID, "codex-cli")
        XCTAssertEqual(merged.terminalBundleIdentifier, "com.mitchellh.ghostty")
        XCTAssertEqual(merged.terminalSessionIdentifier, "terminal-session")
    }
}
