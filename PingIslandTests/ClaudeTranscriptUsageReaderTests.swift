import XCTest
@testable import Ping_Island

final class ClaudeTranscriptUsageReaderTests: XCTestCase {
    func testAppendOnlyGrowthMatchesWholeFileParse() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "incremental")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([usageLine(at: "2026-04-10T00:00:00.000Z", input: 7, output: 4, total: 11)], to: transcriptURL)

        let reader = ClaudeTranscriptUsageReader()
        let first = try await requireSnapshot(from: reader, at: transcriptURL)
        XCTAssertEqual(first.tokenTotals, AgentUsageTokenTotals(input: 7, output: 4, total: 11))

        try appendJSONLLine(usageLine(at: "2026-04-10T00:01:00.000Z", input: 5, output: 4, total: 9), to: transcriptURL)

        let second = try await requireSnapshot(from: reader, at: transcriptURL)
        let wholeFile = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))

        /// Cumulative totals, not just the appended delta — `AgentUsageStore` derives
        /// its own delta from these.
        XCTAssertEqual(second.tokenTotals, AgentUsageTokenTotals(input: 12, output: 8, total: 20))
        XCTAssertEqual(second.tokenTotals, wholeFile.tokenTotals)
        XCTAssertEqual(second.fileSize, wholeFile.fileSize)
        XCTAssertEqual(second.capturedAt, wholeFile.capturedAt)

        /// The carried FNV-1a state must land on the same digest a whole-file pass
        /// produces, or `AgentUsageStore` would treat every append as a new source.
        XCTAssertEqual(second.contentHash, wholeFile.contentHash)
    }

    func testAppendReadsOnlyTheAppendedBytes() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "bytes")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        let padding = String(repeating: "x", count: 32 * 1024)
        try writeJSONLLines(
            [usageLine(at: "2026-04-10T00:00:00.000Z", input: 7, output: 4, total: 11, filler: padding)],
            to: transcriptURL
        )

        let reader = ClaudeTranscriptUsageReader()
        _ = await reader.snapshot(for: transcriptURL)
        let afterFirst = try await requireMetrics(from: reader, at: transcriptURL)
        XCTAssertEqual(afterFirst.fullRebuildCount, 1)
        XCTAssertEqual(afterFirst.incrementalReadCount, 0)
        XCTAssertGreaterThan(afterFirst.lastReadByteCount, 32 * 1024)

        try appendJSONLLine(usageLine(at: "2026-04-10T00:01:00.000Z", input: 5, output: 4, total: 9), to: transcriptURL)

        _ = await reader.snapshot(for: transcriptURL)
        let afterAppend = try await requireMetrics(from: reader, at: transcriptURL)
        XCTAssertEqual(afterAppend.fullRebuildCount, 1, "appending must not trigger a rebuild")
        XCTAssertEqual(afterAppend.incrementalReadCount, 1)

        /// The whole point: the second read touches only the appended record, not the
        /// 32KB that preceded it.
        XCTAssertLessThan(afterAppend.lastReadByteCount, 4 * 1024)
    }

    func testUnchangedFileIsNotReopened() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "unchanged")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([usageLine(at: "2026-04-10T00:00:00.000Z", input: 7, output: 4, total: 11)], to: transcriptURL)

        let reader = ClaudeTranscriptUsageReader()
        let first = try await requireSnapshot(from: reader, at: transcriptURL)
        let second = try await requireSnapshot(from: reader, at: transcriptURL)

        XCTAssertEqual(first, second)

        let metrics = try await requireMetrics(from: reader, at: transcriptURL)
        XCTAssertEqual(metrics.fullRebuildCount, 1)
        XCTAssertEqual(metrics.incrementalReadCount, 0, "an unchanged transcript must not be read again")
    }

    func testTruncationRebuildsWithoutDoubleCounting() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "truncated")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [
                usageLine(at: "2026-04-10T00:00:00.000Z", input: 7, output: 4, total: 11),
                usageLine(at: "2026-04-10T00:01:00.000Z", input: 5, output: 4, total: 9),
            ],
            to: transcriptURL
        )

        let reader = ClaudeTranscriptUsageReader()
        let first = try await requireSnapshot(from: reader, at: transcriptURL)
        XCTAssertEqual(first.tokenTotals, AgentUsageTokenTotals(input: 12, output: 8, total: 20))

        /// Rewriting the file shorter must discard the carried offset and totals rather
        /// than stack a fresh scan on top of stale state.
        try writeJSONLLines([usageLine(at: "2026-04-10T00:02:00.000Z", input: 3, output: 2, total: 5)], to: transcriptURL)

        let second = try await requireSnapshot(from: reader, at: transcriptURL)
        XCTAssertEqual(second.tokenTotals, AgentUsageTokenTotals(input: 3, output: 2, total: 5))

        let wholeFile = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))
        XCTAssertEqual(second.tokenTotals, wholeFile.tokenTotals)
        XCTAssertEqual(second.contentHash, wholeFile.contentHash)
    }

    func testPartiallyWrittenTrailingRecordIsDeferredUntilComplete() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "partial")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([usageLine(at: "2026-04-10T00:00:00.000Z", input: 7, output: 4, total: 11)], to: transcriptURL)

        let reader = ClaudeTranscriptUsageReader()
        _ = try await requireSnapshot(from: reader, at: transcriptURL)

        /// Claude Code can be mid-write when the 100ms debounce fires, so a trailing
        /// fragment without its newline must not be parsed as a record.
        let complete = try jsonLine(usageLine(at: "2026-04-10T00:01:00.000Z", input: 5, output: 4, total: 9))
        let splitIndex = complete.index(complete.startIndex, offsetBy: complete.count / 2)
        try appendRaw(String(complete[..<splitIndex]), to: transcriptURL)

        let midWrite = try await requireSnapshot(from: reader, at: transcriptURL)
        XCTAssertEqual(
            midWrite.tokenTotals,
            AgentUsageTokenTotals(input: 7, output: 4, total: 11),
            "a half-written record must not contribute tokens"
        )

        try appendRaw(String(complete[splitIndex...]) + "\n", to: transcriptURL)

        let completed = try await requireSnapshot(from: reader, at: transcriptURL)
        XCTAssertEqual(completed.tokenTotals, AgentUsageTokenTotals(input: 12, output: 8, total: 20))

        let wholeFile = try XCTUnwrap(ClaudeTranscriptUsageLoader.load(from: transcriptURL))
        XCTAssertEqual(completed.tokenTotals, wholeFile.tokenTotals)
        XCTAssertEqual(completed.contentHash, wholeFile.contentHash)
    }

    func testTranscriptWithoutTokenFieldsReturnsNil() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "notokens")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([
            [
                "timestamp": "2026-04-10T00:03:00.000Z",
                "message": ["role": "assistant", "content": "No usage payload here."],
            ],
        ], to: transcriptURL)

        let reader = ClaudeTranscriptUsageReader()
        let snapshot = await reader.snapshot(for: transcriptURL)
        XCTAssertNil(snapshot)

        /// Offset progress is still cached so the next read tails rather than rescans.
        let metrics = try await requireMetrics(from: reader, at: transcriptURL)
        XCTAssertEqual(metrics.fullRebuildCount, 1)
    }

    func testOversizedTranscriptIsSkipped() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "oversized")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines([usageLine(at: "2026-04-10T00:00:00.000Z", input: 7, output: 4, total: 11)], to: transcriptURL)

        let reader = ClaudeTranscriptUsageReader()
        let snapshot = await reader.snapshot(for: transcriptURL, maxBytesPerFile: 8)
        XCTAssertNil(snapshot, "transcripts past the byte cap keep the previous skip behaviour")
    }

    private func requireSnapshot(
        from reader: ClaudeTranscriptUsageReader,
        at fileURL: URL
    ) async throws -> ClaudeTranscriptUsageSnapshot {
        let snapshot = await reader.snapshot(for: fileURL)
        return try XCTUnwrap(snapshot)
    }

    private func requireMetrics(
        from reader: ClaudeTranscriptUsageReader,
        at fileURL: URL
    ) async throws -> ClaudeTranscriptUsageReader.DebugReadMetrics {
        let metrics = await reader.debugReadMetrics(forFilePath: fileURL.path)
        return try XCTUnwrap(metrics)
    }
}

private func usageLine(
    at timestamp: String,
    input: Int,
    output: Int,
    total: Int,
    filler: String? = nil
) -> [String: Any] {
    var message: [String: Any] = [
        "role": "assistant",
        "usage": [
            "inputTokens": input,
            "outputTokens": output,
            "totalTokens": total,
        ],
    ]
    if let filler {
        message["content"] = filler
    }
    return ["timestamp": timestamp, "message": message]
}

private func temporaryTranscriptURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ping-island-\(name)-reader-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("session.jsonl")
}

private func writeJSONLLines(_ objects: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = try objects.map(jsonLine)
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}

private func appendJSONLLine(_ object: [String: Any], to url: URL) throws {
    try appendRaw(jsonLine(object).appending("\n"), to: url)
}

private func appendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write(Data(text.utf8))
}

private func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
