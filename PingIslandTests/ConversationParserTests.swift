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
        "timestamp": timestamp,
        "message": ["role": "user", "content": [["type": "text", "text": text]]],
    ]
}

private func assistantLine(_ text: String) -> [String: Any] {
    [
        "type": "assistant",
        "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
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

private func writeJSONLLines(_ objects: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = try objects.map { object -> String in
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}
