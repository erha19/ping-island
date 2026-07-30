import XCTest
@testable import NotchCode

final class ClaudeUsageLoaderTests: XCTestCase {
    func testLoadParsesCachedRateLimits() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-claude-usage-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("island-rate-limits.json")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = """
        {
          "five_hour": {
            "used_percentage": 42,
            "resets_at": 1760000000
          },
          "seven_day": {
            "used_percentage": 17.5,
            "resets_at": 1760500000
          }
        }
        """
        try payload.write(to: cacheURL, atomically: true, encoding: .utf8)

        let snapshot = try ClaudeUsageLoader.load(from: cacheURL)

        XCTAssertEqual(snapshot?.fiveHour?.roundedUsedPercentage, 42)
        XCTAssertEqual(snapshot?.sevenDay?.roundedUsedPercentage, 18)
        XCTAssertEqual(snapshot?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertNotNil(snapshot?.cachedAt)
    }

    func testLoadParsesUtilizationPayloadWithISO8601ResetDates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-claude-usage-iso-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("island-rate-limits.json")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = """
        {
          "five_hour": {
            "utilization": 0,
            "resets_at": null
          },
          "seven_day": {
            "utilization": 23,
            "resets_at": "2026-02-09T12:00:00.462679+00:00"
          }
        }
        """
        try payload.write(to: cacheURL, atomically: true, encoding: .utf8)

        let snapshot = try ClaudeUsageLoader.load(from: cacheURL)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertEqual(snapshot?.fiveHour?.roundedUsedPercentage, 0)
        XCTAssertNil(snapshot?.fiveHour?.resetsAt)
        XCTAssertEqual(snapshot?.sevenDay?.roundedUsedPercentage, 23)
        XCTAssertEqual(snapshot?.sevenDay?.resetsAt, formatter.date(from: "2026-02-09T12:00:00.462679+00:00"))
    }

    func testLoadReturnsNilForMissingCacheFile() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-claude-usage-missing-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("island-rate-limits.json")

        let snapshot = try ClaudeUsageLoader.load(from: cacheURL)

        XCTAssertNil(snapshot)
    }
}
