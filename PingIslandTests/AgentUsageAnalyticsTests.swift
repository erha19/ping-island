import XCTest
@testable import NotchCode

final class AgentUsageAnalyticsTests: XCTestCase {
    func testSnapshotAggregatesSelectedRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_775_520_000) // 2026-04-10 00:00:00 UTC
        let today = AgentUsageStore.dayKey(for: now, calendar: calendar)
        let yesterday = AgentUsageStore.dayKey(
            for: calendar.date(byAdding: .day, value: -1, to: now)!,
            calendar: calendar
        )
        let older = AgentUsageStore.dayKey(
            for: calendar.date(byAdding: .day, value: -8, to: now)!,
            calendar: calendar
        )

        let document = AgentUsageDocument(
            buckets: [
                today: AgentUsageDailyBucket(
                    day: today,
                    sessionIDsByAgent: [
                        "Claude Code": ["claude-1", "claude-2"],
                        "Codex": ["codex-1"],
                    ],
                    toolCounts: [
                        "Read": 3,
                        "Bash": 2,
                    ],
                    tokenTotals: AgentUsageTokenTotals(input: 100, output: 50, total: 150),
                    activityCount: 8
                ),
                yesterday: AgentUsageDailyBucket(
                    day: yesterday,
                    sessionIDsByAgent: [
                        "Claude Code": ["claude-2"],
                    ],
                    toolCounts: [
                        "Read": 1,
                    ],
                    tokenTotals: AgentUsageTokenTotals(input: 40, output: 10, total: 50),
                    activityCount: 3
                ),
                older: AgentUsageDailyBucket(
                    day: older,
                    sessionIDsByAgent: [
                        "Gemini CLI": ["gemini-1"],
                    ],
                    toolCounts: [
                        "Grep": 10,
                    ],
                    tokenTotals: AgentUsageTokenTotals(input: 1_000, output: 1_000, total: 2_000),
                    activityCount: 12
                ),
            ]
        )

        let snapshot = AgentUsageStore.makeSnapshot(
            range: .sevenDays,
            document: document,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.sessionCount, 3)
        XCTAssertEqual(snapshot.toolUseCount, 6)
        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 140, output: 60, total: 200))
        XCTAssertEqual(snapshot.topAgents.map(\.name), ["Claude Code", "Codex"])
        XCTAssertEqual(snapshot.topAgents.map(\.count), [2, 1])
        XCTAssertEqual(snapshot.topTools.map(\.name), ["Read", "Bash"])
        XCTAssertEqual(snapshot.topTools.map(\.count), [4, 2])
        XCTAssertEqual(snapshot.heatmapDays.count, 180)
        XCTAssertEqual(snapshot.heatmapDays.last?.activityCount, 8)
        XCTAssertEqual(
            snapshot.heatmapDays.first { AgentUsageStore.dayKey(for: $0.date, calendar: calendar) == older }?.activityCount,
            12
        )
        XCTAssertEqual(snapshot.trendPoints.count, 7)
        XCTAssertEqual(snapshot.trendPoints.last?.tokenTotal, 150)
        XCTAssertEqual(snapshot.trendPoints.last?.agentCount, 2)
        XCTAssertEqual(snapshot.trendPoints.last?.toolUseCount, 5)
        XCTAssertEqual(snapshot.trendPoints.last?.sessionCount, 3)
        XCTAssertEqual(snapshot.spendSummary.dailyPoints.count, 30)
        XCTAssertEqual(snapshot.spendSummary.today.tokenTotals, AgentUsageTokenTotals(input: 100, output: 50, total: 150))
        XCTAssertEqual(snapshot.spendSummary.sevenDays.tokenTotals, AgentUsageTokenTotals(input: 140, output: 60, total: 200))
        XCTAssertEqual(snapshot.spendSummary.thirtyDays.tokenTotals, AgentUsageTokenTotals(input: 1_140, output: 1_060, total: 2_200))
        XCTAssertEqual(
            snapshot.spendSummary.sevenDays.estimatedUSD,
            AgentUsageCostEstimator.estimateUSD(for: AgentUsageTokenTotals(input: 140, output: 60, total: 200)),
            accuracy: 0.000_001
        )
        XCTAssertEqual(snapshot.spendSummary.dailyPoints.last?.tokenTotal, 150)
    }

    func testCostEstimatorUsesBlendedCodexClaudePricing() {
        let cost = AgentUsageCostEstimator.estimateUSD(
            for: AgentUsageTokenTotals(input: 1_000_000, output: 1_000_000, total: 2_000_000)
        )

        XCTAssertEqual(cost, 16.875, accuracy: 0.000_001)
    }

    func testSnapshotRankingsAreLimitedToTopFive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_775_520_000)
        let today = AgentUsageStore.dayKey(for: now, calendar: calendar)

        let document = AgentUsageDocument(
            buckets: [
                today: AgentUsageDailyBucket(
                    day: today,
                    sessionIDsByAgent: [
                        "Agent 1": ["a1"],
                        "Agent 2": ["a2"],
                        "Agent 3": ["a3"],
                        "Agent 4": ["a4"],
                        "Agent 5": ["a5"],
                        "Agent 6": ["a6"],
                    ],
                    toolCounts: [
                        "Tool 1": 60,
                        "Tool 2": 50,
                        "Tool 3": 40,
                        "Tool 4": 30,
                        "Tool 5": 20,
                        "Tool 6": 10,
                    ]
                ),
            ]
        )

        let snapshot = AgentUsageStore.makeSnapshot(
            range: .today,
            document: document,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.topAgents.count, 5)
        XCTAssertEqual(snapshot.topTools.count, 5)
        XCTAssertFalse(snapshot.topAgents.map(\.name).contains("Agent 6"))
        XCTAssertFalse(snapshot.topTools.map(\.name).contains("Tool 6"))
    }

    func testRecordCodexUsageSnapshotStoresOnlyPositiveDeltas() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-agent-usage-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("usage.json")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = AgentUsageStore(fileURL: fileURL, calendar: calendar)
        let capturedAt = Date(timeIntervalSince1970: 1_775_520_000)
        let sourcePath = "/tmp/.codex/sessions/2026/04/10/rollout-2026-04-10T00-00-00-019db9a7-336a-7b62-9288-7304c3d2d4b9.jsonl"

        await store.recordCodexUsageSnapshot(CodexUsageSnapshot(
            sourceFilePath: sourcePath,
            capturedAt: capturedAt,
            planType: "pro",
            limitID: "codex",
            tokenUsage: CodexTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
            windows: []
        ))
        await store.recordCodexUsageSnapshot(CodexUsageSnapshot(
            sourceFilePath: sourcePath,
            capturedAt: capturedAt,
            planType: "pro",
            limitID: "codex",
            tokenUsage: CodexTokenUsage(inputTokens: 175, outputTokens: 80, totalTokens: 255),
            windows: []
        ))

        let snapshot = await store.snapshot(range: .today, now: capturedAt)

        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 75, output: 30, total: 105))
        XCTAssertEqual(snapshot.sessionCount, 1)
    }
}
