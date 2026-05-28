import XCTest
@testable import Ping_Island

final class UsageSnapshotCacheStoreTests: XCTestCase {
    func testSaveAndLoadClaudeSnapshot() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-usage-cache-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let snapshot = ClaudeUsageSnapshot(
            fiveHour: ClaudeUsageWindow(usedPercentage: 12, resetsAt: Date(timeIntervalSince1970: 1_760_000_000)),
            sevenDay: ClaudeUsageWindow(usedPercentage: 44, resetsAt: nil),
            cachedAt: Date(timeIntervalSince1970: 1_760_000_100)
        )

        UsageSnapshotCacheStore.saveClaude(snapshot, to: directoryURL)
        let loaded = UsageSnapshotCacheStore.loadClaude(from: directoryURL)

        XCTAssertEqual(loaded, snapshot)
    }

    func testSaveAndLoadCodexSnapshot() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-usage-cache-codex-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let snapshot = CodexUsageSnapshot(
            sourceFilePath: "/tmp/rollout.jsonl",
            capturedAt: Date(timeIntervalSince1970: 1_775_158_295),
            planType: "pro",
            limitID: "codex",
            tokenUsage: CodexTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
            windows: [
                CodexUsageWindow(
                    key: "primary",
                    label: "5h",
                    usedPercentage: 13,
                    leftPercentage: 87,
                    windowMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 1_775_158_295)
                )
            ]
        )

        UsageSnapshotCacheStore.saveCodex(snapshot, to: directoryURL)
        let loaded = UsageSnapshotCacheStore.loadCodex(from: directoryURL)

        XCTAssertEqual(loaded, snapshot)
    }
}
