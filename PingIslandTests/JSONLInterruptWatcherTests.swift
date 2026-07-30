import Foundation
import XCTest
@testable import NotchCode

final class JSONLInterruptWatcherTests: XCTestCase {
    func testResolveFallbackFilePathPrefersCodexRolloutWhenPresent() throws {
        let sessionId = "watcher-codex-fallback-\(UUID().uuidString)"
        let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions/2099/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let rolloutURL = sessionsDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try "{}\n".write(to: rolloutURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let resolved = JSONLInterruptWatcher.resolveFallbackFilePath(
            sessionId: sessionId,
            cwd: "/Users/ping-island/github/CodeIsland"
        )

        XCTAssertEqual(resolved, rolloutURL.path)
    }

    func testRetryDelayUsesExponentialBackoffWithCap() {
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 0), .milliseconds(250))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 1), .milliseconds(500))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 2), .milliseconds(1_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 3), .milliseconds(2_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 4), .milliseconds(4_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 5), .milliseconds(5_000))
        XCTAssertEqual(JSONLInterruptWatcher.retryDelay(forMissingFileAttempt: 99), .milliseconds(5_000))
    }
}
