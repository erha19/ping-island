import XCTest
@testable import Ping_Island

final class ConversationParserTests: XCTestCase {
    func testCustomTitleIsPreferredOverFirstUserMessage() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "custom-title")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [
                userLine("修复一下窗口重复显示的问题", at: "2026-08-30T10:00:00.000Z"),
                customTitleLine("双窗口重复显示bug"),
                assistantLine("Patched the docked window teardown path."),
            ],
            to: transcriptURL
        )

        let info = await parse(transcriptURL)

        XCTAssertEqual(info.summary, "双窗口重复显示bug")
        XCTAssertEqual(info.firstUserMessage, "修复一下窗口重复显示的问题")
    }

    /// Claude Code rewrites the `custom-title` record on every turn, and the title
    /// changes as the session moves on. The newest one has to win.
    func testLatestCustomTitleWins() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "latest-title")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [
                userLine("先看看标题为什么不对", at: "2026-08-30T10:00:00.000Z"),
                customTitleLine("排查标题来源"),
                assistantLine("Found the parser gap."),
                userLine("好的，修复一下", at: "2026-08-30T10:05:00.000Z"),
                customTitleLine("会话标题解析修复"),
                assistantLine("Patched ConversationParser."),
            ],
            to: transcriptURL
        )

        let info = await parse(transcriptURL)

        XCTAssertEqual(info.summary, "会话标题解析修复")
    }

    /// Older transcripts (and other Claude-compatible clients) still ship `summary`
    /// records, so that path must keep working.
    func testLegacySummaryRecordStillParses() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "legacy-summary")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [
                ["type": "summary", "summary": "Ship stable completion handling"],
                userLine("ship it", at: "2026-08-30T10:00:00.000Z"),
                assistantLine("Released."),
            ],
            to: transcriptURL
        )

        let info = await parse(transcriptURL)

        XCTAssertEqual(info.summary, "Ship stable completion handling")
    }

    func testTranscriptWithoutTitleFallsBackToFirstUserMessage() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "no-title")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [
                userLine("just a quick question", at: "2026-08-30T10:00:00.000Z"),
                assistantLine("Here is the answer."),
            ],
            to: transcriptURL
        )

        let info = await parse(transcriptURL)

        XCTAssertNil(info.summary)
        XCTAssertEqual(info.firstUserMessage, "just a quick question")
    }

    func testBlankCustomTitleIsIgnored() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "blank-title")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [
                userLine("blank title please", at: "2026-08-30T10:00:00.000Z"),
                customTitleLine("   "),
                assistantLine("Done."),
            ],
            to: transcriptURL
        )

        let info = await parse(transcriptURL)

        XCTAssertNil(info.summary)
        XCTAssertEqual(info.firstUserMessage, "blank title please")
    }

    // MARK: - Missing transcripts

    /// A session that has not written its transcript yet must not adopt a
    /// sibling's. The "newest .jsonl in the same directory" fallback exists for
    /// OpenClaw, whose transcripts rotate out from under the reported path; aimed
    /// at `~/.claude/projects/<workspace>/` it turned a session that started and
    /// ended without writing anything into a duplicate of whichever session wrote
    /// last — same title, same messages, same token totals, its own row.
    func testMissingClaudeTranscriptDoesNotAdoptASiblingInTheSameDirectory() async throws {
        let neighbourURL = temporaryTranscriptURL(named: "live-neighbour")
        let workspace = neighbourURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try writeJSONLLines(
            [
                userLine("这个会话正在运行", at: "2026-08-30T10:00:00.000Z"),
                customTitleLine("正在运行的会话"),
                assistantLine("Still working."),
            ],
            to: neighbourURL
        )

        let missingURL = workspace.appendingPathComponent("never-written.jsonl")
        let parser = ConversationParser()
        let info = await parser.parse(
            sessionId: "never-written",
            cwd: workspace.path,
            explicitFilePath: missingURL.path
        )

        XCTAssertNil(info.summary, "A session with no transcript must not inherit a neighbour's title")
        XCTAssertNil(info.firstUserMessage)
        XCTAssertNil(info.lastMessage)
    }

    /// The rotation fallback still has to work for the client it was written for.
    func testMissingOpenClawTranscriptStillFallsBackToTheNewestSessionFile() async throws {
        let sessionsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-openclaw-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".openclaw/agents/main/sessions", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: sessionsDirectory.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        }

        let rotatedURL = sessionsDirectory.appendingPathComponent("rotated.jsonl")
        try writeJSONLLines(
            [
                openClawLine("openclaw rotated this file", role: "user"),
                openClawLine("Rotated transcript content.", role: "assistant"),
            ],
            to: rotatedURL
        )

        let reportedURL = sessionsDirectory.appendingPathComponent("reported-but-gone.jsonl")
        let parser = ConversationParser()
        let info = await parser.parse(
            sessionId: "reported-but-gone",
            cwd: sessionsDirectory.path,
            explicitFilePath: reportedURL.path
        )

        XCTAssertEqual(
            info.firstUserMessage,
            "openclaw rotated this file",
            "OpenClaw transcripts rotate, so a missing reported path still resolves to the newest session file"
        )
    }

    // MARK: - Incremental reads

    /// Every hook schedules a debounced sync, so a sync routinely runs against a
    /// transcript that has not grown since the last one — the `Stop` hook's sync
    /// always does. That has to read as "nothing new", not as the whole
    /// conversation arriving at once.
    func testUnchangedTranscriptYieldsNoNewMessages() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "unchanged")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [
                userLine("先跑一下测试", at: "2026-08-30T10:00:00.000Z"),
                assistantLine("Tests pass."),
            ],
            to: transcriptURL
        )

        let parser = ConversationParser()
        let sessionId = "unchanged-session"
        let cwd = transcriptURL.deletingLastPathComponent().path

        let first = await parser.parseIncremental(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: transcriptURL.path
        )
        XCTAssertFalse(first.newMessages.isEmpty, "The first read has the whole file to catch up on")

        let second = await parser.parseIncremental(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: transcriptURL.path
        )

        XCTAssertTrue(
            second.newMessages.isEmpty,
            "An unchanged transcript has no new messages; replaying the conversation reads as fresh activity"
        )
        XCTAssertEqual(
            second.allMessages.count,
            first.newMessages.count,
            "The accumulated conversation stays available through allMessages"
        )
    }

    /// A real append still has to come through, and only the appended part.
    func testAppendedLinesAreReportedAsTheOnlyNewMessages() async throws {
        let transcriptURL = temporaryTranscriptURL(named: "appended")
        defer { try? FileManager.default.removeItem(at: transcriptURL.deletingLastPathComponent()) }

        try writeJSONLLines(
            [userLine("第一轮", at: "2026-08-30T10:00:00.000Z")],
            to: transcriptURL
        )

        let parser = ConversationParser()
        let sessionId = "appended-session"
        let cwd = transcriptURL.deletingLastPathComponent().path

        _ = await parser.parseIncremental(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: transcriptURL.path
        )

        try appendJSONLLine(assistantLine("Second turn."), to: transcriptURL)

        let second = await parser.parseIncremental(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: transcriptURL.path
        )

        XCTAssertEqual(second.newMessages.count, 1)
        XCTAssertEqual(second.allMessages.count, 2)
    }

    private func parse(_ url: URL) async -> ConversationInfo {
        let parser = ConversationParser()
        return await parser.parse(
            sessionId: url.deletingPathExtension().lastPathComponent,
            cwd: url.deletingLastPathComponent().path,
            explicitFilePath: url.path
        )
    }
}

private func userLine(_ text: String, at timestamp: String) -> [String: Any] {
    [
        "type": "user",
        "uuid": UUID().uuidString,
        "timestamp": timestamp,
        "message": ["role": "user", "content": [["type": "text", "text": text]]],
    ]
}

private func assistantLine(_ text: String) -> [String: Any] {
    [
        "type": "assistant",
        "uuid": UUID().uuidString,
        "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
    ]
}

/// OpenClaw records one `message` envelope per line rather than Claude's
/// `type: user` / `type: assistant` pair.
private func openClawLine(_ text: String, role: String) -> [String: Any] {
    [
        "type": "message",
        "id": UUID().uuidString,
        "message": ["role": role, "content": [["type": "text", "text": text]]],
    ]
}

private func customTitleLine(_ title: String) -> [String: Any] {
    ["type": "custom-title", "customTitle": title]
}

private func temporaryTranscriptURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ping-island-\(name)-parser-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("session.jsonl")
}

private func appendJSONLLine(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let line = String(decoding: data, as: UTF8.self) + "\n"
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
}

private func writeJSONLLines(_ objects: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = try objects.map { object -> String in
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}
