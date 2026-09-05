import XCTest
@testable import Ping_Island

final class ClaudeDesktopSessionIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var accountDirectory: URL {
        root.appendingPathComponent("org-1").appendingPathComponent("account-1")
    }

    private func writeSession(
        localSessionId: String,
        cliSessionId: String,
        isArchived: Bool = false,
        lastActivityAt: TimeInterval = 1_700_000_000_000,
        extra: [String: Any] = [:]
    ) throws {
        var json: [String: Any] = [
            "sessionId": localSessionId,
            "cliSessionId": cliSessionId,
            "cwd": "/tmp/demo",
            "isArchived": isArchived,
            "lastActivityAt": lastActivityAt
        ]
        json.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: accountDirectory.appendingPathComponent("\(localSessionId).json"))
    }

    func testResolvesDesktopTabForCLISessionId() async throws {
        try writeSession(
            localSessionId: "local_3c664429-88cf-4483-b690-475f2e74cfcb",
            cliSessionId: "dfbf4536-bae7-48b9-aa15-e45866eaf003"
        )

        let index = ClaudeDesktopSessionIndex(roots: [root])
        let deepLink = await index.tabDeepLink(forCLISessionId: "dfbf4536-bae7-48b9-aa15-e45866eaf003")

        XCTAssertEqual(deepLink, "claude://claude.ai/epitaxy/local_3c664429-88cf-4483-b690-475f2e74cfcb")
    }

    func testArchivedSessionsHaveNoTab() async throws {
        try writeSession(
            localSessionId: "local_archived",
            cliSessionId: "cli-archived",
            isArchived: true
        )

        let index = ClaudeDesktopSessionIndex(roots: [root])
        let localSessionId = await index.localSessionIdentifier(forCLISessionId: "cli-archived")

        XCTAssertNil(localSessionId)
    }

    func testPrefersMostRecentlyActiveSessionForARepeatedCLISessionId() async throws {
        try writeSession(
            localSessionId: "local_older",
            cliSessionId: "shared-cli",
            lastActivityAt: 1_700_000_000_000
        )
        try writeSession(
            localSessionId: "local_newer",
            cliSessionId: "shared-cli",
            lastActivityAt: 1_800_000_000_000
        )

        let index = ClaudeDesktopSessionIndex(roots: [root])
        let localSessionId = await index.localSessionIdentifier(forCLISessionId: "shared-cli")

        XCTAssertEqual(localSessionId, "local_newer")
    }

    func testMatchesSessionsAdoptedFromATerminalByTheirDerivedIdentifier() async throws {
        // Imported CLI sessions are stored as `local_<cliSessionId>`; the metadata may still
        // point `cliSessionId` at a post-clear id.
        try writeSession(
            localSessionId: "local_a1b2c3d4",
            cliSessionId: "e5f6a7b8",
            extra: ["preClearCliSessionId": "c9d0e1f2"]
        )

        let index = ClaudeDesktopSessionIndex(roots: [root])
        let derived = await index.localSessionIdentifier(forCLISessionId: "a1b2c3d4")
        let preClear = await index.localSessionIdentifier(forCLISessionId: "c9d0e1f2")

        XCTAssertEqual(derived, "local_a1b2c3d4")
        XCTAssertEqual(preClear, "local_a1b2c3d4")
    }

    func testPicksUpSessionsWrittenAfterTheFirstLookup() async throws {
        let index = ClaudeDesktopSessionIndex(roots: [root])
        let missing = await index.localSessionIdentifier(forCLISessionId: "late-cli")
        XCTAssertNil(missing)

        try writeSession(localSessionId: "local_late", cliSessionId: "late-cli")
        await index.invalidate()

        let resolved = await index.localSessionIdentifier(forCLISessionId: "late-cli")
        XCTAssertEqual(resolved, "local_late")
    }

    func testIgnoresTranscriptDirectoriesNextToTheMetadataFiles() throws {
        let sessionDirectory = accountDirectory.appendingPathComponent("local_with_transcript")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data().write(to: sessionDirectory.appendingPathComponent("audit.jsonl"))
        try writeSession(localSessionId: "local_with_transcript", cliSessionId: "cli-1")

        let urls = ClaudeDesktopSessionIndex.metadataFileURLs(in: [root])

        XCTAssertEqual(urls.map(\.lastPathComponent), ["local_with_transcript.json"])
    }

    func testRecognizesClaudeDesktopHostedSessions() {
        let hookSession = SessionClientInfo(
            kind: .claudeCode,
            name: "Claude Code",
            terminalBundleIdentifier: "com.anthropic.claudefordesktop"
        )
        let watcherSession = SessionClientInfo(
            kind: .custom,
            profileID: "claude-desktop",
            name: "Claude Desktop",
            bundleIdentifier: "com.anthropic.claudefordesktop"
        )
        let terminalSession = SessionClientInfo(
            kind: .claudeCode,
            name: "Claude Code",
            terminalBundleIdentifier: "com.mitchellh.ghostty"
        )

        XCTAssertTrue(SessionLauncher.isClaudeDesktopHostedSession(provider: .claude, clientInfo: hookSession))
        XCTAssertTrue(SessionLauncher.isClaudeDesktopHostedSession(provider: .claude, clientInfo: watcherSession))
        XCTAssertFalse(SessionLauncher.isClaudeDesktopHostedSession(provider: .claude, clientInfo: terminalSession))
        XCTAssertFalse(SessionLauncher.isClaudeDesktopHostedSession(provider: .codex, clientInfo: watcherSession))
    }
}
