import XCTest
@testable import Ping_Island

final class ClaudeTranscriptUsageLoaderTests: XCTestCase {
    func testLoadParsesClaudeMessageUsage() throws {
        let transcriptURL = temporaryTranscriptURL(named: "claude")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([
            [
                "timestamp": "2026-04-10T00:00:00.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "usage": [
                        "input_tokens": 10,
                        "cache_creation_input_tokens": 2,
                        "cache_read_input_tokens": 3,
                        "output_tokens": 5,
                    ],
                ],
            ],
        ], to: transcriptURL)

        let snapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        // Cache tiers stay separate: `input` is the uncached 10, and the 3 cache-read
        // tokens are excluded from `total` because they are a re-read, not new spend.
        XCTAssertEqual(
            snapshot.tokenTotals,
            AgentUsageTokenTotals(input: 10, cacheCreation: 2, cacheRead: 3, output: 5, total: 17)
        )
        XCTAssertEqual(snapshot.tokenTotals.billableInput, 12)
        XCTAssertEqual(snapshot.tokenTotals.contextProcessed, 15)
        XCTAssertEqual(snapshot.sourceFilePath, transcriptURL.path)
        XCTAssertFalse(snapshot.contentHash.isEmpty)
    }

    func testLoadParsesQoderCamelCaseUsage() throws {
        let transcriptURL = temporaryTranscriptURL(named: "qoder")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([
            [
                "timestamp": "2026-04-10T00:01:00.000Z",
                "message": [
                    "role": "assistant",
                    "usage": [
                        "inputTokens": 7,
                        "outputTokens": 4,
                        "totalTokens": 11,
                    ],
                ],
            ],
        ], to: transcriptURL)

        let snapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 7, output: 4, total: 11))
    }

    func testLoadParsesQoderWorkTopLevelUsage() throws {
        let transcriptURL = temporaryTranscriptURL(named: "qoderwork")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([
            [
                "timestamp": "2026-04-10T00:02:00.000Z",
                "usage": [
                    "prompt_tokens": "13",
                    "completion_tokens": "8",
                    "total_tokens": "21",
                ],
            ],
        ], to: transcriptURL)

        let snapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 13, output: 8, total: 21))
    }

    func testLoadReturnsNilWhenTranscriptHasNoTokenFields() throws {
        let transcriptURL = temporaryTranscriptURL(named: "empty")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([
            [
                "timestamp": "2026-04-10T00:03:00.000Z",
                "message": [
                    "role": "assistant",
                    "content": "No usage payload here.",
                ],
            ],
        ], to: transcriptURL)

        XCTAssertNil(try ClaudeTranscriptUsageLoader.load(from: transcriptURL))
    }

    func testLoadCountsOneAPIResponseOnceWhenSplitAcrossContentBlocks() throws {
        let transcriptURL = temporaryTranscriptURL(named: "split-blocks")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        // Claude Code writes one assistant response as several lines, one per content
        // block, each repeating the same `message.usage`.
        let usage: [String: Any] = [
            "input_tokens": 4,
            "cache_creation_input_tokens": 100,
            "cache_read_input_tokens": 50_000,
            "output_tokens": 20,
        ]
        try writeJSONLLines([
            [
                "timestamp": "2026-04-10T00:00:00.000Z",
                "type": "assistant",
                "requestId": "req_1",
                "message": [
                    "id": "msg_1",
                    "role": "assistant",
                    "content": [["type": "thinking", "thinking": "..."]],
                    "usage": usage,
                ],
            ],
            [
                "timestamp": "2026-04-10T00:00:01.000Z",
                "type": "assistant",
                "requestId": "req_1",
                "message": [
                    "id": "msg_1",
                    "role": "assistant",
                    "content": [["type": "tool_use", "id": "t1", "name": "Bash"]],
                    "usage": usage,
                ],
            ],
        ], to: transcriptURL)

        let snapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        XCTAssertEqual(
            snapshot.tokenTotals,
            AgentUsageTokenTotals(
                input: 4,
                cacheCreation: 100,
                cacheRead: 50_000,
                output: 20,
                total: 124
            )
        )
    }

    func testLoadCountsDistinctResponsesSeparately() throws {
        let transcriptURL = temporaryTranscriptURL(named: "distinct-responses")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        // Guards the O(1) dedup: only a *repeat* of the previous id collapses. Two real
        // responses must both count, and an id reappearing after another one still counts.
        func line(id: String, at timestamp: String) -> [String: Any] {
            [
                "timestamp": timestamp,
                "type": "assistant",
                "message": [
                    "id": id,
                    "role": "assistant",
                    "usage": ["input_tokens": 5, "output_tokens": 1],
                ],
            ]
        }
        try writeJSONLLines([
            line(id: "msg_a", at: "2026-04-10T00:00:00.000Z"),
            line(id: "msg_b", at: "2026-04-10T00:00:01.000Z"),
            line(id: "msg_a", at: "2026-04-10T00:00:02.000Z"),
        ], to: transcriptURL)

        let snapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        XCTAssertEqual(snapshot.tokenTotals.input, 15)
        XCTAssertEqual(snapshot.tokenTotals.output, 3)
    }

    func testLoadStillCountsEveryLineWhenProviderOmitsMessageID() throws {
        let transcriptURL = temporaryTranscriptURL(named: "no-message-id")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        // Providers without `message.id` (Qoder and friends) must not be deduplicated,
        // or their per-line totals would be silently dropped.
        let line: [String: Any] = [
            "timestamp": "2026-04-10T00:00:00.000Z",
            "message": [
                "role": "assistant",
                "usage": ["inputTokens": 7, "outputTokens": 4, "totalTokens": 11],
            ],
        ]
        try writeJSONLLines([line, line], to: transcriptURL)

        let snapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 14, output: 8, total: 22))
    }

    func testRecordTranscriptUsageDoesNotDoubleCountRepeatedReads() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-transcript-usage-store-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = rootURL.appendingPathComponent("session.jsonl")
        let usageURL = rootURL.appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeJSONLLines([
            [
                "timestamp": "2026-04-10T00:00:00.000Z",
                "message": [
                    "role": "assistant",
                    "usage": [
                        "inputTokens": 7,
                        "outputTokens": 4,
                        "totalTokens": 11,
                    ],
                ],
            ],
        ], to: transcriptURL)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_775_779_200)
        let store = AgentUsageStore(fileURL: usageURL, calendar: calendar)
        let clientInfo = SessionClientInfo(
            kind: .qoder,
            profileID: "qoder",
            name: "Qoder",
            sessionFilePath: transcriptURL.path
        )
        let sourceKey = "transcript|claude|qoder-session|\(transcriptURL.path)"
        let firstSnapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        await store.recordTokenUsage(
            provider: .claude,
            clientInfo: clientInfo,
            sessionID: "qoder-session",
            sourceKey: sourceKey,
            totals: firstSnapshot.tokenTotals,
            capturedAt: firstSnapshot.capturedAt ?? now,
            sourceFileSize: firstSnapshot.fileSize,
            sourceContentHash: firstSnapshot.contentHash
        )
        await store.recordTokenUsage(
            provider: .claude,
            clientInfo: clientInfo,
            sessionID: "qoder-session",
            sourceKey: sourceKey,
            totals: firstSnapshot.tokenTotals,
            capturedAt: firstSnapshot.capturedAt ?? now,
            sourceFileSize: firstSnapshot.fileSize,
            sourceContentHash: firstSnapshot.contentHash
        )

        var snapshot = await store.snapshot(range: .today, now: now)
        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 7, output: 4, total: 11))
        XCTAssertEqual(snapshot.sessionCount, 1)

        try appendJSONLLine([
            "timestamp": "2026-04-10T00:04:00.000Z",
            "message": [
                "role": "assistant",
                "usage": [
                    "inputTokens": 5,
                    "outputTokens": 4,
                    "totalTokens": 9,
                ],
            ],
        ], to: transcriptURL)

        let secondSnapshot = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))
        await store.recordTokenUsage(
            provider: .claude,
            clientInfo: clientInfo,
            sessionID: "qoder-session",
            sourceKey: sourceKey,
            totals: secondSnapshot.tokenTotals,
            capturedAt: secondSnapshot.capturedAt ?? now,
            sourceFileSize: secondSnapshot.fileSize,
            sourceContentHash: secondSnapshot.contentHash
        )

        snapshot = await store.snapshot(range: .today, now: now)
        XCTAssertEqual(snapshot.tokenTotals, AgentUsageTokenTotals(input: 12, output: 8, total: 20))
        XCTAssertEqual(snapshot.sessionCount, 1)
    }
}

private func temporaryTranscriptURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ping-island-\(name)-transcript-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("session.jsonl")
}

private func writeJSONLLines(_ objects: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = try objects.map(jsonLine)
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}

private func appendJSONLLine(_ object: [String: Any], to url: URL) throws {
    let line = try jsonLine(object).appending("\n")
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write(Data(line.utf8))
}

private func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
