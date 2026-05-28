import XCTest
@testable import Ping_Island

final class CodexUsageLoaderTests: XCTestCase {
    func testLoadParsesLastTokenCountRateLimits() throws {
        let rootURL = temporaryRootURL(named: "codex-usage")
        let rolloutURL = rootURL
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-latest.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T01:49:35.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 600_000,
                                "output_tokens": 399_999,
                                "total_tokens": 999_999,
                            ],
                        ],
                        "rate_limits": [
                            "limit_id": "codex",
                            "plan_type": "pro",
                            "primary": [
                                "used_percent": 12.0,
                                "window_minutes": 300,
                                "resets_at": 1_775_158_295,
                            ],
                            "secondary": [
                                "used_percent": 24.0,
                                "window_minutes": 10_080,
                                "resets_at": 1_775_635_184,
                            ],
                        ],
                    ]
                ),
                rolloutLine(
                    timestamp: "2026-04-03T01:50:35.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 800_000,
                                "output_tokens": 434_567,
                                "total_tokens": 1_234_567,
                            ],
                        ],
                        "rate_limits": [
                            "limit_id": "codex",
                            "plan_type": "pro",
                            "primary": [
                                "used_percent": 13.0,
                                "window_minutes": 300,
                                "resets_at": 1_775_158_295,
                            ],
                            "secondary": [
                                "used_percent": 25.0,
                                "window_minutes": 10_080,
                                "resets_at": 1_775_635_184,
                            ],
                        ],
                    ]
                ),
            ],
            to: rolloutURL
        )
        try setModificationDate(Date(timeIntervalSince1970: 2_000), for: rolloutURL)

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        XCTAssertEqual(resolvedPath(snapshot?.sourceFilePath), rolloutURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(snapshot?.limitID, "codex")
        XCTAssertEqual(snapshot?.planType, "pro")
        XCTAssertEqual(snapshot?.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(snapshot?.windows.map(\.roundedUsedPercentage), [13, 25])
        XCTAssertEqual(snapshot?.tokenUsage, CodexTokenUsage(inputTokens: 800_000, outputTokens: 434_567, totalTokens: 1_234_567))
        XCTAssertEqual(snapshot?.windows.first?.leftPercentage ?? -1, 87, accuracy: 0.001)
        XCTAssertEqual(snapshot?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_775_158_295))
        XCTAssertEqual(snapshot?.capturedAt, isoDate("2026-04-03T01:50:35.000Z"))
    }

    func testLoadFallsBackWhenNewestRolloutHasNoRateLimits() throws {
        let rootURL = temporaryRootURL(named: "codex-usage-fallback")
        let oldRolloutURL = rootURL
            .appendingPathComponent("2026/04/02", isDirectory: true)
            .appendingPathComponent("rollout-has-rate-limits.jsonl")
        let newRolloutURL = rootURL
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-no-rate-limits.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-02T17:54:17.621Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "rate_limits": [
                            "limit_id": "codex",
                            "plan_type": "pro",
                            "primary": [
                                "used_percent": 13.0,
                                "window_minutes": 300,
                                "resets_at": 1_775_158_295,
                            ],
                        ],
                    ]
                ),
            ],
            to: oldRolloutURL
        )
        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T03:00:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "user_message",
                        "message": "Start a fresh session.",
                    ]
                ),
            ],
            to: newRolloutURL
        )

        try setModificationDate(Date(timeIntervalSince1970: 1_000), for: oldRolloutURL)
        try setModificationDate(Date(timeIntervalSince1970: 2_000), for: newRolloutURL)

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        XCTAssertEqual(resolvedPath(snapshot?.sourceFilePath), oldRolloutURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(snapshot?.windows.map(\.label), ["5h"])
        XCTAssertEqual(snapshot?.windows.first?.roundedUsedPercentage, 13)
    }

    func testLoadFormatsNonStandardWindowLengths() throws {
        let rootURL = temporaryRootURL(named: "codex-usage-labels")
        let rolloutURL = rootURL
            .appendingPathComponent("2026/04/03", isDirectory: true)
            .appendingPathComponent("rollout-custom-window.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeRollout(
            [
                rolloutLine(
                    timestamp: "2026-04-03T05:30:00.000Z",
                    type: "event_msg",
                    payload: [
                        "type": "token_count",
                        "rate_limits": [
                            "primary": [
                                "used_percent": 8.0,
                                "window_minutes": 90,
                                "resets_at": 1_775_200_000,
                            ],
                            "secondary": [
                                "used_percent": 11.0,
                                "window_minutes": 1_500,
                                "resets_at": 1_775_260_000,
                            ],
                        ],
                    ]
                ),
            ],
            to: rolloutURL
        )

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        XCTAssertEqual(snapshot?.windows.map(\.label), ["1h 30m", "1d 1h"])
    }

    func testLoadReturnsNilWhenNoValidRolloutsExist() throws {
        let rootURL = temporaryRootURL(named: "codex-usage-empty")
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let snapshot = try CodexUsageLoader.load(fromRootURL: rootURL)

        XCTAssertNil(snapshot)
    }

    func testSnapshotExtractsThreadIDFromRolloutPath() {
        let snapshot = CodexUsageSnapshot(
            sourceFilePath: "/tmp/.codex/sessions/2026/04/23/rollout-2026-04-23T17-23-55-019db9a7-336a-7b62-9288-7304c3d2d4b9.jsonl",
            capturedAt: nil,
            planType: nil,
            limitID: nil,
            tokenUsage: nil,
            windows: []
        )

        XCTAssertEqual(snapshot.threadID, "019db9a7-336a-7b62-9288-7304c3d2d4b9")
    }

    func testSnapshotThreadIDIsNilForNonThreadRolloutPath() {
        let snapshot = CodexUsageSnapshot(
            sourceFilePath: "/tmp/.codex/sessions/2026/04/23/rollout-latest.jsonl",
            capturedAt: nil,
            planType: nil,
            limitID: nil,
            tokenUsage: nil,
            windows: []
        )

        XCTAssertNil(snapshot.threadID)
    }
}

private func temporaryRootURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ping-island-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func writeRollout(_ lines: [String], to url: URL) throws {
    let directoryURL = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}

private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func isoDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

private func resolvedPath(_ value: String?) -> String? {
    guard let value else {
        return nil
    }

    return URL(fileURLWithPath: value).resolvingSymlinksInPath().path
}

private func rolloutLine(
    timestamp: String,
    type: String,
    payload: [String: Any]
) -> String {
    let object: [String: Any] = [
        "timestamp": timestamp,
        "type": type,
        "payload": payload,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
