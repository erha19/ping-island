import XCTest
@testable import Ping_Island

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

    func testSnapshotBuildsRecentTodaySessionsAndCalendarWeekTopSession() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 10,
            hour: 12
        ))!
        let today = AgentUsageStore.dayKey(for: now, calendar: calendar)
        let mondayDate = calendar.date(byAdding: .day, value: -4, to: now)!
        let monday = AgentUsageStore.dayKey(for: mondayDate, calendar: calendar)
        let previousSundayDate = calendar.date(byAdding: .day, value: -5, to: now)!
        let previousSunday = AgentUsageStore.dayKey(for: previousSundayDate, calendar: calendar)

        let document = AgentUsageDocument(
            buckets: [
                today: AgentUsageDailyBucket(
                    day: today,
                    sessionRecords: [
                        "oldest": AgentUsageSessionRecord(
                            sessionID: "oldest",
                            agent: "Claude Code",
                            title: "Oldest today",
                            lastActivityAt: now.addingTimeInterval(-4_000),
                            tokenTotals: AgentUsageTokenTotals(total: 100)
                        ),
                        "recent-1": AgentUsageSessionRecord(
                            sessionID: "recent-1",
                            agent: "Codex",
                            title: "Recent one",
                            lastActivityAt: now.addingTimeInterval(-300),
                            tokenTotals: AgentUsageTokenTotals(total: 200)
                        ),
                        "recent-2": AgentUsageSessionRecord(
                            sessionID: "recent-2",
                            agent: "Claude Code",
                            title: "Recent two",
                            lastActivityAt: now.addingTimeInterval(-200),
                            tokenTotals: AgentUsageTokenTotals(total: 300)
                        ),
                        "recent-3": AgentUsageSessionRecord(
                            sessionID: "recent-3",
                            agent: "Codex",
                            title: "Recent three",
                            lastActivityAt: now.addingTimeInterval(-100),
                            tokenTotals: AgentUsageTokenTotals(total: 50)
                        ),
                    ]
                ),
                monday: AgentUsageDailyBucket(
                    day: monday,
                    sessionRecords: [
                        "recent-1": AgentUsageSessionRecord(
                            sessionID: "recent-1",
                            agent: "Codex",
                            title: "Recent one",
                            lastActivityAt: mondayDate,
                            tokenTotals: AgentUsageTokenTotals(total: 500)
                        ),
                    ]
                ),
                previousSunday: AgentUsageDailyBucket(
                    day: previousSunday,
                    sessionRecords: [
                        "recent-2": AgentUsageSessionRecord(
                            sessionID: "recent-2",
                            agent: "Claude Code",
                            title: "Recent two",
                            lastActivityAt: previousSundayDate,
                            tokenTotals: AgentUsageTokenTotals(total: 2_000)
                        ),
                    ]
                ),
            ]
        )

        let snapshot = AgentUsageStore.makeSnapshot(
            range: .sevenDays,
            document: document,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.recentTodaySessions.map(\.sessionID), ["recent-3", "recent-2", "recent-1"])
        XCTAssertEqual(snapshot.recentTodayTokenTotals.resolvedTotal, 550)
        XCTAssertEqual(snapshot.topSessionThisWeek?.sessionID, "recent-1")
        XCTAssertEqual(snapshot.topSessionThisWeek?.tokenTotals.resolvedTotal, 700)

        let titledSnapshot = snapshot.applyingSessionTitles([
            "recent-1": "Current session title",
            "recent-2": "Updated recent title",
        ])
        XCTAssertEqual(
            titledSnapshot.recentTodaySessions.first { $0.sessionID == "recent-1" }?.title,
            "Current session title"
        )
        XCTAssertEqual(
            titledSnapshot.recentTodaySessions.first { $0.sessionID == "recent-2" }?.title,
            "Updated recent title"
        )
        XCTAssertEqual(titledSnapshot.topSessionThisWeek?.title, "Current session title")
    }

    func testDailyBucketDecodesLegacyDocumentWithoutSessionRecords() throws {
        let data = try XCTUnwrap(
            """
            {
              "day": "2026-04-10",
              "sessionIDsByAgent": {"Codex": ["codex-1"]},
              "toolCounts": {},
              "tokenTotals": {"input": 10, "output": 5, "total": 15},
              "activityCount": 1
            }
            """.data(using: .utf8)
        )

        let bucket = try JSONDecoder().decode(AgentUsageDailyBucket.self, from: data)

        XCTAssertTrue(bucket.sessionRecords.isEmpty)
        XCTAssertEqual(bucket.tokenTotals.resolvedTotal, 15)
    }

    func testLegacyDocumentDropsPreV2TokenCountersButKeepsActivityHistory() throws {
        // A pre-v2 ledger: no schemaVersion, and token counters recorded on the old
        // merged scale where cache reads were folded into `input`.
        let data = try XCTUnwrap(
            """
            {
              "buckets": {
                "2026-04-10": {
                  "day": "2026-04-10",
                  "sessionIDsByAgent": {"Claude Code": ["claude-1"]},
                  "toolCounts": {"Read": 4},
                  "tokenTotals": {"input": 81756491, "output": 398236, "total": 82154727},
                  "activityCount": 7
                }
              },
              "seenToolEventIDs": [],
              "codexTokenBaselines": {},
              "tokenBaselines": {
                "transcript|claude|s1|/tmp/does-not-exist.jsonl": {
                  "totals": {"input": 79458365, "output": 388469, "total": 79846834},
                  "fileSize": 1024,
                  "contentHash": "abc"
                }
              }
            }
            """.data(using: .utf8)
        )

        let document = try JSONDecoder().decode(AgentUsageDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, AgentUsageDocument.currentSchemaVersion)

        // Inflated token counters are gone...
        let bucket = try XCTUnwrap(document.buckets["2026-04-10"])
        XCTAssertEqual(bucket.tokenTotals, AgentUsageTokenTotals())

        // ...while the parts that were never wrong survive.
        XCTAssertEqual(bucket.sessionIDsByAgent["Claude Code"], ["claude-1"])
        XCTAssertEqual(bucket.toolCounts["Read"], 4)
        XCTAssertEqual(bucket.activityCount, 7)

        // The baseline is retained but marked legacy, so the next read re-baselines
        // instead of replaying the transcript's lifetime total into today.
        let baseline = try XCTUnwrap(
            document.tokenBaselines["transcript|claude|s1|/tmp/does-not-exist.jsonl"]
        )
        XCTAssertNil(baseline.schemaVersion)
        XCTAssertEqual(baseline.totals, AgentUsageTokenTotals())
    }

    func testLegacyBaselineIsRebaselinedWithoutEmittingADelta() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_775_520_000)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-usage-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent("usage.json")

        let legacy = """
        {
          "buckets": {},
          "seenToolEventIDs": [],
          "codexTokenBaselines": {},
          "tokenBaselines": {
            "transcript|claude|s1|\(rootURL.path)/session.jsonl": {
              "totals": {"input": 79458365, "output": 388469, "total": 79846834}
            }
          }
        }
        """
        try legacy.write(to: fileURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: rootURL.appendingPathComponent("session.jsonl").path, contents: Data("{}\n".utf8))

        let store = AgentUsageStore(fileURL: fileURL, calendar: calendar)
        let clientInfo = SessionClientInfo(kind: .claudeCode, profileID: "claude", name: "Claude Code")

        // First read after the upgrade must record nothing: subtracting a stale scale
        // would clamp to zero anyway, and treating it as a fresh source would dump the
        // whole transcript into today.
        await store.recordTokenUsage(
            provider: .claude,
            clientInfo: clientInfo,
            sessionID: "s1",
            sourceKey: "transcript|claude|s1|\(rootURL.path)/session.jsonl",
            totals: AgentUsageTokenTotals(input: 100, cacheCreation: 20, cacheRead: 5_000, output: 30, total: 150),
            capturedAt: now,
            now: now
        )
        let afterMigration = await store.snapshot(range: .today, now: now)
        XCTAssertEqual(afterMigration.tokenTotals, AgentUsageTokenTotals())

        // The next read is a normal delta against the re-established baseline.
        await store.recordTokenUsage(
            provider: .claude,
            clientInfo: clientInfo,
            sessionID: "s1",
            sourceKey: "transcript|claude|s1|\(rootURL.path)/session.jsonl",
            totals: AgentUsageTokenTotals(input: 150, cacheCreation: 20, cacheRead: 9_000, output: 45, total: 215),
            capturedAt: now,
            now: now
        )
        let afterDelta = await store.snapshot(range: .today, now: now)
        XCTAssertEqual(afterDelta.tokenTotals.input, 50)
        XCTAssertEqual(afterDelta.tokenTotals.cacheRead, 4_000)
        XCTAssertEqual(afterDelta.tokenTotals.output, 15)
    }

    func testCostEstimatorPricesCacheReadsBelowFreshInput() {
        // One million cache-read tokens must not cost the same as one million fresh
        // input tokens; that equivalence is what inflated the spend estimate.
        let cacheHeavy = AgentUsageTokenTotals(cacheRead: 1_000_000)
        let freshInput = AgentUsageTokenTotals(input: 1_000_000)

        let cacheCost = AgentUsageCostEstimator.estimateUSD(for: cacheHeavy)
        let inputCost = AgentUsageCostEstimator.estimateUSD(for: freshInput)

        XCTAssertEqual(cacheCost, inputCost * 0.1, accuracy: 0.0001)
        XCTAssertLessThan(cacheCost, inputCost)
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
        await store.recordCodexUsageSnapshot(
            CodexUsageSnapshot(
                sourceFilePath: sourcePath,
                capturedAt: capturedAt,
                planType: "pro",
                limitID: "codex",
                tokenUsage: CodexTokenUsage(inputTokens: 175, outputTokens: 80, totalTokens: 255),
                windows: []
            ),
            sessionTitle: "Display token usage by session title"
        )

        let snapshot = await store.snapshot(range: .today, now: capturedAt)

        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 75, output: 30, total: 105))
        XCTAssertEqual(snapshot.sessionCount, 1)
        XCTAssertEqual(snapshot.recentTodaySessions.map(\.sessionID), ["019db9a7-336a-7b62-9288-7304c3d2d4b9"])
        XCTAssertEqual(snapshot.recentTodaySessions.first?.title, "Display token usage by session title")
        XCTAssertEqual(snapshot.recentTodayTokenTotals, AgentUsageTokenTotals(input: 75, output: 30, total: 105))
        XCTAssertEqual(snapshot.topSessionThisWeek?.tokenTotals, AgentUsageTokenTotals(input: 75, output: 30, total: 105))
        XCTAssertEqual(snapshot.topSessionThisWeek?.title, "Display token usage by session title")
    }
}
